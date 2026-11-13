#!/usr/bin/env python3
"""Disposable-kernel witnesses using only the production monitor CLI/JSON ABI."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

CONTROL = Path('/proc/rtnl_monitor_fixture')
STATE = Path('/run/rtnl-monitor-test')
CGROUP = Path('/sys/fs/cgroup')
PARENT = CGROUP / 'rtnl-monitor-fixture'
BINARY = '/run/current-system/sw/bin/osctl-rtnl-monitor'
MS_NS = 1_000_000
REQUIRED = {
    'schema', 'type', 'epoch', 'sequence', 'monotonic_ns', 'available',
    'assessment_valid', 'coverage', 'owner_supported', 'pending_calls',
    'pending_vps', 'oldest_pending_ms', 'unmapped_pending', 'mapping_age_ms',
    'loss_total', 'alarm', 'vps',
}


def until(predicate, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError('condition timed out')


def mapping_published(row, epoch, generated_ns):
    # With a millisecond-aligned generation, subtracting the floored age from
    # the floored snapshot clock exactly identifies the accepted publication.
    assert generated_ns % MS_NS == 0
    return (row['epoch'] == epoch and row['available'] and row['assessment_valid'] and
            row['pending_calls'] == 0 and row['loss_total'] == 0 and
            row['monotonic_ns'] // MS_NS - row['mapping_age_ms'] == generated_ns // MS_NS)


def cpu_delta(before, after, ticks_per_second):
    elapsed = (after['monotonic_ns'] - before['monotonic_ns']) / 1e9
    ticks = (after['utime_ticks'] - before['utime_ticks'] +
             after['stime_ticks'] - before['stime_ticks'])
    assert elapsed > 0 and ticks_per_second > 0 and ticks >= 0
    return {'start': before, 'end': after, 'clock_ticks_per_second': ticks_per_second,
            'elapsed_seconds': elapsed, 'cpu_ticks_delta': ticks,
            'cpu_seconds_delta': ticks / ticks_per_second,
            'cpu_tick_seconds': 1 / ticks_per_second,
            'native_one_core_fraction': ticks / ticks_per_second / elapsed,
            'one_core_fraction_resolution': 1 / ticks_per_second / elapsed,
            'below_one_tick': ticks == 0}


def release():
    (CONTROL / 'release').write_text('release\n')


def status(pid):
    rows = (CONTROL / 'status').read_text().splitlines()[1:]
    return next((row.split() for row in rows if int(row.split()[0]) == pid), None)


def in_group(path):
    def move():
        (path / 'cgroup.procs').write_text(str(os.getpid()))
    return move


def call(api='lock', group=None, hold=0, iterations=1):
    return subprocess.Popen(
        [sys.executable, __file__, '--call', api, str(hold), str(iterations)],
        preexec_fn=in_group(group) if group else None,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )


class Monitor:
    def __init__(self, manifest, *extra):
        self.metrics = STATE / 'monitor.prom'
        self.metrics.unlink(missing_ok=True)
        self.stderr = (STATE / 'monitor.stderr').open('w+')
        self.process = subprocess.Popen([
            BINARY, '--roots-file', str(manifest), '--metrics-file', str(self.metrics),
            '--interval-ms', '100', '--wait-ms', '300', '--min-vps', '3',
            '--confirm-frames', '2', *extra,
        ], stdout=subprocess.PIPE, stderr=self.stderr)
        fcntl.fcntl(self.process.stdout, fcntl.F_SETPIPE_SZ, 4096)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.records = []
        self.output_bytes = 0
        self.last_frame = None

    def pump(self, timeout=0.02):
        if self.selector.select(timeout):
            data = os.read(self.process.stdout.fileno(), 65536)
            self.output_bytes += len(data)
            self.buffer += data
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                record = json.loads(line)
                if record.get('type') == 'snapshot':
                    assert REQUIRED <= record.keys(), record
                    assert record['schema'] == 1, record
                    assert record['coverage'] == 'global_blocking_wrappers_v1', record
                    assert record['owner_supported'] is False, record
                    assert len(record['vps']) <= 1024, record
                    assert len({(v['pool'], v['id']) for v in record['vps']}) == len(record['vps'])
                    if self.last_frame:
                        assert record['epoch'] == self.last_frame['epoch'], record
                        assert record['sequence'] > self.last_frame['sequence'], record
                        assert record['monotonic_ns'] > self.last_frame['monotonic_ns'], record
                    self.last_frame = record
                self.records.append(record)
        return self.records

    def require_running(self):
        code = self.process.poll()
        if code is not None:
            self.stderr.flush()
            raise AssertionError({
                'exit': code, 'records': self.records[-6:],
                'stderr': (STATE / 'monitor.stderr').read_text()[-4096:],
            })

    def frame(self, predicate=lambda row: row['assessment_valid'], timeout=5):
        start = len(self.records)

        def matching():
            self.pump()
            self.require_running()
            rows = [r for r in self.records[start:] if r.get('type') == 'snapshot']
            return next((row for row in reversed(rows) if predicate(row)), None)

        try:
            return until(matching, timeout)
        except AssertionError:
            self.stderr.flush()
            raise AssertionError({
                'exit': self.process.poll(), 'records': self.records[-6:],
                'stderr': (STATE / 'monitor.stderr').read_text()[-4096:],
            })

    def cpu_sample(self):
        fields = Path(f'/proc/{self.process.pid}/stat').read_text().rsplit(')', 1)[1].split()
        return {'utime_ticks': int(fields[11]), 'stime_ticks': int(fields[12]),
                'monotonic_ns': time.monotonic_ns()}

    def stats(self):
        cpu = self.cpu_sample()
        memory = Path(f'/proc/{self.process.pid}/status').read_text().splitlines()
        maps = []
        for info in Path(f'/proc/{self.process.pid}/fdinfo').glob('*'):
            try:
                lines = info.read_text().splitlines()
            except FileNotFoundError:
                continue  # A short-lived metrics/inventory file descriptor closed.
            for line in lines:
                if line.startswith('map_id:'):
                    maps.append(json.loads(subprocess.check_output(
                        ['bpftool', '-j', 'map', 'show', 'id', line.split()[1]], text=True)))
        return {
            'cpu_seconds_since_start': (cpu['utime_ticks'] + cpu['stime_ticks']) / os.sysconf('SC_CLK_TCK'),
            'memory': [s for s in memory if s.startswith(('VmRSS:', 'VmHWM:'))],
            'maps': maps,
        }

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        self.process.wait(timeout=5)
        self.pump()
        self.selector.close()
        self.process.stdout.close()
        self.stderr.close()


class Fixture:
    def __init__(self):
        STATE.mkdir(exist_ok=True)
        self.leaves = []
        self.roots = []
        self.children = []
        self.monitors = []
        self.manifest = STATE / 'roots.json'
        self.generated_ns = 0
        for name in ('a', 'b', 'c'):
            root = PARENT / f'ct.{name}'
            leaves = [root / 'user-owned' / f'child{i}' for i in range(3)]
            for leaf in leaves:
                leaf.mkdir(parents=True, exist_ok=True)
            self.leaves.append(leaves)
            self.roots.append({
                'pool': 'fixture', 'id': name,
                'path': str(root.relative_to(CGROUP)), 'run_token': f'{name}-run1',
            })
        self.publish()

    def publish(self, mount=CGROUP, roots=None):
        # Wait for actual clock progress on rapid consecutive publications;
        # never manufacture a future timestamp to make it unique.
        generated_ns = until(lambda: value if
                             (value := time.monotonic_ns() // MS_NS * MS_NS) > self.generated_ns
                             else None)
        temporary = self.manifest.with_suffix('.tmp')
        temporary.write_text(json.dumps({
            'schema': 1, 'generated_monotonic_ns': generated_ns,
            'cgroup_mount': str(mount), 'roots': self.roots if roots is None else roots,
        }))
        temporary.chmod(0o600)
        temporary.replace(self.manifest)
        self.generated_ns = generated_ns
        return generated_ns

    def monitor(self, *extra):
        monitor = Monitor(self.manifest, *extra)
        self.monitors.append(monitor)
        return monitor

    def writer(self, api='lock', root=0, child=0, hold=0, iterations=1):
        process = call(api, self.leaves[root][child] if root is not None else None,
                       hold, iterations)
        self.children.append(process)
        return process

    def holder(self):
        process = self.writer(root=None, hold=9000)
        until(lambda: status(process.pid) and status(process.pid)[3] == '1')
        return process

    def blocked(self, process):
        row = status(process.pid)
        assert process.poll() is None and row and row[2:4] == ['1', '0'], row

    def finish(self):
        release()
        for process in self.children:
            if process.poll() is None:
                process.wait(timeout=10)
            process.communicate()
        for monitor in self.monitors:
            monitor.stop()
        if PARENT.exists():
            for path in sorted(PARENT.rglob('*'), key=lambda p: len(p.parts), reverse=True):
                if path.is_dir():
                    path.rmdir()
            PARENT.rmdir()


def startup(f):
    monitor = f.monitor('--stacks', 'off')
    required = {'ready', 'coverage_details'}
    frame = monitor.frame(lambda row: row['available'] and row['assessment_valid'] and
                          required <= {r.get('reason') for r in monitor.records
                                       if r.get('type') == 'status'})
    return {'snapshot': frame, 'status_reasons': sorted(required)}


def contention(f):
    monitor = f.monitor('--stacks', 'off')
    monitor.frame()
    holder = f.holder()
    nested = [f.writer(child=i) for i in range(3)]
    first = monitor.frame(lambda r: r['pending_calls'] >= 3 and r['pending_vps'] == 1)
    assert first['alarm'] is False, first
    contenders = nested + [f.writer(root=i) for i in (1, 2)]
    alarm = monitor.frame(lambda r: r['alarm'] is True)
    assert alarm['pending_vps'] == 3 and len(alarm['vps']) == 3, alarm
    assert alarm['oldest_pending_ms'] >= 300, alarm
    for process in contenders:
        f.blocked(process)
    assert status(holder.pid)[3] == '1'
    release()
    for process in contenders + [holder]:
        assert process.wait(timeout=3) == 0
    monitor.frame(lambda r: r['assessment_valid'] and r['pending_calls'] == 0)
    return {'alarm_while_blocked': alarm, 'nested_root_count': first['pending_vps']}


def safety(f):
    # Do not send release: prove the maximum accepted hold expires in-kernel.
    start = time.monotonic()
    holder = f.holder()
    assert holder.wait(timeout=10) == 0
    elapsed = time.monotonic() - start
    assert elapsed >= 8.5, elapsed
    assert not status(holder.pid) or status(holder.pid)[2:4] == ['0', '0']
    excessive = f.writer(hold=10000)
    assert excessive.wait(timeout=2) != 0
    return {'maximum_hold_elapsed_seconds': elapsed, 'over_limit_rejected': True}


def variants(f):
    monitor = f.monitor('--stacks', 'off')
    monitor.frame()
    holder = f.holder()
    for api in ('try', 'ref2'):
        process = f.writer(api)
        assert process.wait(timeout=2) == 0
        row = status(process.pid)
        assert row[-1] == '0', row
    killed = f.writer('killable')
    monitor.frame(lambda r: r['pending_vps'] == 1)
    f.blocked(killed)
    killed.kill()
    assert killed.wait(timeout=2) == -signal.SIGKILL
    monitor.frame(lambda r: r['pending_calls'] == 0)
    assert status(killed.pid)[-1] == '-4'  # -EINTR, never acquired.
    # This is an otherwise disposable VM PID namespace. Reuse the exact host
    # pid_tgid in a different root to detect stale pending-key attribution.
    Path('/proc/sys/kernel/ns_last_pid').write_text(str(killed.pid - 1))
    reused = f.writer('killable', root=1)
    assert reused.pid == killed.pid, 'another guest fork raced the PID-reuse witness'
    reused_frame = monitor.frame(lambda r: r['pending_vps'] == 1)
    assert [v['id'] for v in reused_frame['vps']] == ['b'], reused_frame
    assert reused_frame['loss_total'] == 0, reused_frame
    reused.kill()
    assert reused.wait(timeout=2) == -signal.SIGKILL
    monitor.frame(lambda r: r['pending_calls'] == 0)
    ordinary = f.writer()
    conditional = f.writer('ref1', root=1)
    successful = f.writer('killable', root=2)
    monitor.frame(lambda r: r['alarm'] is True)
    for process in (ordinary, conditional, successful):
        f.blocked(process)
    release()
    for process in (ordinary, conditional, successful, holder):
        assert process.wait(timeout=3) == 0
    assert status(conditional.pid)[-1] == '1'
    assert status(successful.pid)[-1] == '0'
    process = f.writer('try')
    assert process.wait(timeout=2) == 0 and status(process.pid)[-1] == '1'
    monitor.frame(lambda r: r['assessment_valid'] and r['pending_calls'] == 0)
    # Additional short-lived tasks exercise real exit cleanup.
    for _ in range(12):
        assert f.writer('ref2').wait(timeout=2) == 0
    monitor.frame(lambda r: r['pending_calls'] == 0 and r['loss_total'] == 0)
    return {'variants': ['lock', 'killable-success', 'killable-EINTR', 'try-0/1', 'ref1/2'],
            'reused_pid': reused.pid, 'reused_root': reused_frame}


def mapping(f):
    monitor = f.monitor('--stacks', 'off')
    epoch = monitor.frame()['epoch']
    f.holder()
    contenders = [f.writer(root=i) for i in range(3)]
    monitor.frame(lambda r: r['alarm'] is True)
    # Current-run replacement must invalidate entry-time tokens even if the
    # cgroup directories have not yet been removed and recreated.
    for root in f.roots:
        root['run_token'] += '-replacement'
    f.publish()
    replaced = monitor.frame(lambda r: r['unmapped_pending'] >= 3 and r['pending_vps'] == 0)
    assert replaced['alarm'] is not True, replaced
    release()
    for process in contenders:
        assert process.wait(timeout=3) == 0
    monitor.frame(lambda r: r['pending_calls'] == 0)
    # Recreate a root at the same path; old handles/tokens must not count it.
    for leaf in f.leaves[0]:
        leaf.rmdir()
    f.leaves[0][0].parent.rmdir()
    f.leaves[0][0].parent.parent.rmdir()
    for leaf in f.leaves[0]:
        leaf.mkdir(parents=True, exist_ok=True)
    f.roots[0]['run_token'] += '-new-root'
    generated_ns = f.publish()
    # Entry-time attribution cannot relabel a caller that entered before the
    # asynchronous mapper accepted this recreated root. Witness that exact
    # publication in the same epoch before starting a fresh caller.
    publication = monitor.frame(lambda r: mapping_published(r, epoch, generated_ns))
    f.holder()
    contender = f.writer()
    fresh = monitor.frame(lambda r: r['assessment_valid'] and r['pending_vps'] == 1)
    assert fresh['epoch'] == epoch and fresh['available'] and fresh['unmapped_pending'] == 0, fresh
    assert [(v['pool'], v['id']) for v in fresh['vps']] == [('fixture', 'a')], fresh
    f.blocked(contender)
    return {'replaced_pending': replaced, 'recreated_generation_ns': generated_ns,
            'publication': publication, 'fresh_pending': fresh}


def stale(f):
    monitor = f.monitor('--mapping-max-age-ms', '1000', '--stacks', 'off')
    # Keep the startup heartbeat fresh even on a slow verifier; then stop it.
    def initially_valid():
        f.publish()
        monitor.pump()
        monitor.require_running()
        return next((r for r in reversed(monitor.records)
                     if r.get('type') == 'snapshot' and r['assessment_valid']), None)
    until(initially_valid)
    invalid = monitor.frame(lambda r: not r['assessment_valid'] and r['alarm'] is None)
    assert invalid['mapping_age_ms'] >= 1000, invalid
    return {'stale': invalid}


def overflow(f):
    monitor = f.monitor('--max-pending', '2', '--stacks', 'off')
    monitor.frame()
    f.holder()
    for i in range(3):
        f.writer(root=i)
    invalid = monitor.frame(lambda r: r['loss_total'] > 0 and r['alarm'] is None)
    assert not invalid['assessment_valid'], invalid
    release()
    after = monitor.frame(lambda r: r['pending_calls'] == 0)
    assert after['loss_total'] >= invalid['loss_total'] and after['alarm'] is None, after
    return {'overflow': invalid, 'sticky_loss': after}


def unavailable(f):
    capped = f.monitor('--max-roots', '2')
    def rejected():
        capped.pump()
        result = next((r for r in capped.records if r.get('available') is False or
                       (r.get('type') == 'snapshot' and r['alarm'] is None and
                        not r['assessment_valid'])), None)
        if not result:
            capped.require_running()
        return result
    rejection = until(rejected)
    assert not any(r.get('alarm') is False for r in capped.records), capped.records
    capped.stop()
    f.monitors.remove(capped)
    # A child directory shares the hierarchy's filesystem/mount ID but is not
    # its root. Make paths valid relative to that child so a false acceptance
    # cannot be hidden by a later nonexistent-path error.
    f.publish(mount=PARENT, roots=[dict(root, path=f"ct.{root['id']}") for root in f.roots])
    child_mount = f.monitor('--stacks', 'off')
    def mapping_rejected():
        child_mount.pump()
        child_mount.require_running()
        return next((r for r in child_mount.records if r.get('reason') == 'mapping_invalid'), None)
    invalid_status = until(mapping_rejected)
    invalid_frame = child_mount.frame(lambda r: not r['assessment_valid'] and r['alarm'] is None)
    assert not any(r.get('alarm') is False for r in child_mount.records), child_mount.records
    child_mount.stop()
    f.monitors.remove(child_mount)
    f.publish()
    object_path = Path(os.environ['RTNL_MONITOR_BPF_OBJECT'])
    damaged = STATE / 'missing-hook.bpf.o'
    original = object_path.read_bytes()
    assert b'rtnl_lock\0' in original
    damaged.write_bytes(original.replace(b'rtnl_lock\0', b'rtnl_nope\0'))
    monitor = f.monitor('--bpf-object', str(damaged))
    until(lambda: monitor.process.poll() is not None)
    monitor.pump()
    assert monitor.process.returncode != 0
    assert any(r.get('available') is False for r in monitor.records), monitor.records
    assert not any(r.get('alarm') is False for r in monitor.records), monitor.records
    return {'root_cap': rejection, 'child_mount_status': invalid_status,
            'child_mount_frame': invalid_frame, 'missing_hook': monitor.records}


def diagnostics(f):
    monitor = f.monitor()
    monitor.frame()
    for i in range(3):
        assert f.writer(root=i, iterations=20).wait(timeout=3) == 0
    monitor.frame()
    stacks = [r for r in monitor.records if r.get('type') == 'stack']
    # Entry sampling is optional, but an unsupported helper must say so.
    assert stacks or any(r.get('reason') == 'stacks_disabled' or
                         r.get('loss', {}).get('stack_capture', 0) > 0
                         for r in monitor.records), monitor.records
    by_window = {}
    for record in stacks:
        assert record['association'] == 'entry_time_call_sample', record
        assert record['owner_supported'] is False and record['schema'] == 1, record
        assert record['epoch'] == monitor.last_frame['epoch'], record
        assert len(record['frames']) <= 32 and record['api'] in (1, 2, 3), record
        assert isinstance(record['mapping_current'], bool), record
        window = record['entered_ns'] // 30_000_000_000
        peers = by_window.setdefault(window, [])
        peers.append(record)
        assert len(peers) <= 4, peers
        if record['mapping_current']:
            identity = (record['pool'], record['id'])
            assert sum((r.get('pool'), r.get('id')) == identity for r in peers) == 1, peers
    maps = monitor.stats()['maps']
    stack_maps = [row for item in maps for row in (item if isinstance(item, list) else [item])
                  if row['type'] == 'stack_trace']
    assert stack_maps and all(row['max_entries'] == 256 and row['bytes_value'] == 32 * 8
                              for row in stack_maps), maps
    holder = f.holder()
    contenders = [f.writer(root=i) for i in range(3)]
    alarm = monitor.frame(lambda r: r['alarm'] is True)
    # Stop draining the fixed-size stdout pipe. This faithfully blocks the
    # optional diagnostic/output consumer, not the aggregator or BPF hooks.
    before = monitor.metrics.read_text()
    time.sleep(2)
    after = monitor.metrics.read_text()
    assert before != after, 'textfile stopped while stdout consumer was blocked'
    def samples(text):
        return {line.split()[0]: float(line.split()[1]) for line in text.splitlines()
                if line and not line.startswith('#')}
    earlier, current = samples(before), samples(after)
    prefix = 'osctl_rtnl_monitor_'
    assert current[prefix + 'snapshot_timestamp_seconds'] > earlier[prefix + 'snapshot_timestamp_seconds'], after
    for key, value in (('available', 1), ('assessment_valid', 1), ('pending_vps', 3), ('alarm', 1)):
        assert current[prefix + key] == value, after
    assert current[prefix + 'loss_total{reason="output"}'] > 0, after
    for process in contenders:
        f.blocked(process)
    held = status(holder.pid)
    assert held and held[3] == '1', held
    resumed = monitor.frame(lambda r: r['loss']['output'] > 0 and
                            r['assessment_valid'] and r['alarm'] is True, timeout=3)
    assert resumed['sequence'] > alarm['sequence'], resumed
    for process in contenders:
        f.blocked(process)
    held = status(holder.pid)
    assert held and held[3] == '1', held
    return {'stack_records': len(stacks), 'stack_maps': stack_maps,
            'output_backpressure_metrics': current, 'output_backpressure': resumed}


def overhead(f):
    rows = []
    workloads = ('idle', 'network', 'contender', 'cpu')
    for workload in workloads:
        for enabled in (False, True):
            f.publish()
            monitor = f.monitor('--stacks', 'off') if enabled else None
            if monitor:
                monitor.frame()
            start = time.monotonic()
            processes = []
            if workload == 'network':
                processes = [subprocess.Popen(['ip', '-batch', '-'], stdin=subprocess.PIPE)]
                processes[0].stdin.write(b'link set lo up\n' * 300)
                processes[0].stdin.close()
            elif workload == 'contender':
                processes = [f.writer(root=i, iterations=2000) for i in range(3)]
            elif workload == 'cpu':
                processes = [subprocess.Popen([sys.executable, __file__, '--burn', '2'],
                             preexec_fn=in_group(f.leaves[i % 3][0])) for i in range(4)]
                # Short acquisition calls compete with CPU-only load. A
                # preempted call can age without a deliberate RTNL hold.
                processes += [f.writer(root=i, iterations=2000) for i in range(3)]
            else:
                processes = [subprocess.Popen(['sleep', '2'])]
            while any(p.poll() is None for p in processes):
                if monitor:
                    # Both branches use the same completion-polling cadence.
                    monitor.pump(timeout=0)
                    monitor.require_running()
                time.sleep(0.01)
            assert all(p.wait() == 0 for p in processes)
            elapsed = time.monotonic() - start
            if monitor:
                latest = monitor.frame()
                frame_age_ms = (time.monotonic_ns() - latest['monotonic_ns']) / 1e6
                if workload == 'idle':
                    assert latest['loss']['output'] == 0, latest
                frames = [r for r in monitor.records if r.get('type') == 'snapshot']
                alarms = [r for r in frames if r['alarm'] is True]
                # Preserve any CPU/preemption alarms in the measured result.
                # They are acquisition-call observations, not RTNL sleep proof.
                rows.append({'workload': workload, 'enabled': enabled,
                             'profile': 'stress_100ms_stacks_off',
                             'elapsed_seconds': elapsed, 'monitor': monitor.stats(),
                             'snapshot_count': len(frames), 'snapshot': latest,
                             'control_alarm_frames': alarms,
                             'control_alarm_count': len(alarms),
                             'deliberate_rtnl_hold': False,
                             'workload_operations': {'network': 300, 'contender': 6000}.get(workload),
                             'output_bytes': monitor.output_bytes,
                             'frame_age_ms_before_map_stats': frame_age_ms,
                             'max_frame_gap_ms': max((b['monotonic_ns'] - a['monotonic_ns']) / 1e6
                                 for a, b in zip(frames, frames[1:])) if len(frames) > 1 else None})
                monitor.stop()
                f.monitors.remove(monitor)
            else:
                rows.append({'workload': workload, 'enabled': enabled, 'elapsed_seconds': elapsed,
                             'profile': 'stress_100ms_stacks_off',
                             'workload_operations': {'network': 300, 'contender': 6000}.get(workload)})
    ratios = {name: next(r['elapsed_seconds'] for r in rows if r['workload'] == name and r['enabled']) /
              next(r['elapsed_seconds'] for r in rows if r['workload'] == name and not r['enabled'])
              for name in workloads}
    defaults = {'interval_ms': 1000, 'wait_ms': 1000, 'min_vps': 3, 'confirm_frames': 2,
                'max_pending': 4096, 'max_roots': 1024, 'mapping_max_age_ms': 30000,
                'stacks': 'entry'}
    f.publish()
    options = [item for key, value in defaults.items()
               for item in ('--' + key.replace('_', '-'), str(value))]
    monitor = f.monitor(*options)
    warmup = [monitor.frame(), monitor.frame()]
    generated_ns = f.publish()
    publication = monitor.frame(lambda r: mapping_published(r, warmup[-1]['epoch'], generated_ns))
    ticks_per_second = os.sysconf('SC_CLK_TCK')
    first_record = len(monitor.records)
    before = monitor.cpu_sample()
    # Only lightweight process clocks and nonblocking output draining occur
    # inside this interval. BPF map/memory inspection follows the end sample.
    while time.monotonic_ns() - before['monotonic_ns'] < 10_000_000_000:
        monitor.pump(timeout=0)
        monitor.require_running()
        time.sleep(0.01)
    after = monitor.cpu_sample()
    latest = monitor.frame()
    frame_age_ms = (time.monotonic_ns() - latest['monotonic_ns']) / 1e6
    frames = [r for r in monitor.records[first_record:] if r.get('type') == 'snapshot']
    assert frames and all(r['available'] and r['assessment_valid'] and r['loss_total'] == 0 and
                          r['pending_calls'] == 0 and r['alarm'] is False for r in frames), frames
    default_idle = {'settings': defaults, 'root_count': len(f.roots),
                    'warmup_sequences': [r['sequence'] for r in warmup],
                    'publication': publication, 'cpu_window': cpu_delta(before, after, ticks_per_second),
                    'frame_age_ms_before_map_stats': frame_age_ms, 'snapshot': latest,
                    'monitor': monitor.stats(),
                    'scope': 'Native userspace core only; excludes caller BPF, inventory adapter and full-node cost.'}
    monitor.stop()
    f.monitors.remove(monitor)
    return {'samples': rows, 'on_off_elapsed_ratios': ratios,
            'stress_settings': {'interval_ms': 100, 'wait_ms': 300, 'stacks': 'off'},
            'warmed_default_idle': default_idle,
            'qualification': 'One paired disposable-VM sample per workload; scheduler noise is unbounded. '
                             'Stress CPU totals include startup; snapshot/output/map observations include '
                             'startup and collection outside the workload window. Zero delta ticks only '
                             'establish the reported clock-resolution limit.'}


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--call':
        api, hold, iterations = sys.argv[2:]
        for _ in range(int(iterations)):
            (CONTROL / 'call').write_text(f'{api} {hold}\n')
        return
    if len(sys.argv) > 1 and sys.argv[1] == '--burn':
        end = time.monotonic() + float(sys.argv[2])
        while time.monotonic() < end:
            pass
        return
    parser = argparse.ArgumentParser()
    parser.add_argument('scenario', choices=SCENARIOS)
    args = parser.parse_args()
    fixture = Fixture()
    try:
        result = SCENARIOS[args.scenario](fixture)
        print(json.dumps({'scenario': args.scenario, 'result': result}, sort_keys=True))
    finally:
        fixture.finish()


SCENARIOS = {f.__name__: f for f in (startup, contention, safety, variants, mapping, stale, overflow,
                                    unavailable, diagnostics, overhead)}
if __name__ == '__main__':
    main()
