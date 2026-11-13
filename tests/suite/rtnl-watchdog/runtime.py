#!/usr/bin/env python3
"""Actual packaged lean stream, guarded daemon and two-slot action witnesses."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from fixture import STATE, Watchdog, command, holder, release, slot, until

CGROUP = Path('/sys/fs/cgroup')
IDS = ('watchdog-a', 'watchdog-b')
# Retain 4 MiB in the init shell so the real memory predicate remains eligible
# while leaving room for the Ruby attach runner inside the container's limit.
BALLAST = ('ballast=xxxxxxxxxxxxxxxx\nballast_steps=0\n'
           'while [ "$ballast_steps" -lt 18 ]; do\n'
           '  ballast="$ballast$ballast"; ballast_steps=$((ballast_steps + 1))\n'
           'done\n')


def info(ct):
    return json.loads(command('osctl', '-j', 'ct', 'show', ct))


def identity(ct):
    row = info(ct)
    pid = row['init_pid']
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    assert info(ct)['init_pid'] == pid
    return [pid, int(fields[19])]


class Containers:
    def __init__(self, names):
        self.names = names
        self.created = []

    def start(self):
        for ct in self.names:
            command('osctl', 'ct', 'new', '--skip-image', '--distribution', 'alpine',
                    '--version', 'latest', '--arch', 'x86_64', ct)
            self.created.append(ct)
            command('osctl', 'ct', 'unset', 'start-menu', ct)
            command('osctl', 'ct', 'set', 'memory', ct, '128M')
            # The retained v2 reader truncates fractional-core limits. Keep a
            # positive representable denominator without changing that reader.
            command('osctl', 'ct', 'set', 'cpu-limit', ct, '100')
            command('osctl', 'ct', 'mount', ct)
            root = Path(info(ct)['rootfs'])
            for directory in ('bin', 'sbin', 'proc', 'sys', 'dev', 'root', 'tmp', 'run', 'var', 'etc/network'):
                (root / directory).mkdir(parents=True, exist_ok=True)
            shutil.copyfile('/etc/rtnl-watchdog-test-busybox', root / 'bin/busybox')
            (root / 'bin/busybox').chmod(0o555)
            (root / 'bin/sh').symlink_to('busybox')
            init = root / 'sbin/watchdog-test-init'
            init.write_text('#!/bin/busybox sh\ntrap "exit 0" INT TERM PWR\n' + BALLAST +
                            '(while :; do :; done) &\n'
                            'while :; do /bin/busybox sleep 1 & wait "$!"; done\n')
            init.chmod(0o555)
            (root / 'root/watchdog-sentinel').write_text(f'{ct}:retained\n')
            command('osctl', 'ct', 'set', 'init-cmd', ct, '/sbin/watchdog-test-init')
            command('osctl', 'ct', 'start', ct)
            until(lambda: info(ct)['state'] == 'running', timeout=20)
        return self

    def finish(self):
        for ct in reversed(self.created):
            if info(ct)['state'] == 'running':
                command('osctl', 'ct', 'stop', '--kill', ct, timeout=30)
            command('osctl', 'ct', 'del', '--prune', ct, timeout=30)


class Stream:
    def __init__(self):
        STATE.mkdir(exist_ok=True)
        self.stderr = (STATE / 'lean.stderr').open('w+', errors='replace')
        self.process = subprocess.Popen(['osctl', '-j', 'ct', 'top', '--oomd', '--rate', '1'],
                                        stdout=subprocess.PIPE, stderr=self.stderr)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.last = None

    def frame(self, names):
        def read():
            assert self.process.poll() is None, self.process.returncode
            if self.selector.select(0):
                self.buffer += os.read(self.process.stdout.fileno(), 65536)
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                row = json.loads(line)
                if self.last:
                    assert row['epoch'] == self.last['epoch'] and row['sequence'] > self.last['sequence'], row
                self.last = row
                if row['complete']:
                    check_raw(row, names)
                    return row
            return None
        try:
            return until(read, timeout=10)
        except Exception as error:
            self.stderr.flush()
            self.stderr.seek(0, os.SEEK_END)
            self.stderr.seek(max(0, self.stderr.tell() - 4096))
            error.add_note(json.dumps({'pid': self.process.pid, 'exit': self.process.poll(),
                                       'last_frame': self.last,
                                       'stdout_tail': self.buffer[-4096:].decode(errors='replace'),
                                       'stderr': self.stderr.read()[-4096:]}, sort_keys=True))
            raise

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        self.selector.close()
        self.process.stdout.close()
        self.stderr.close()


def check_raw(row, names, expected_runs=None, *, at_ns=None):
    assert row['oomd_schema'] == 1 and row['complete'] is True, row
    start, end = row['sample_started_monotonic_ns'], row['sample_completed_monotonic_ns']
    now = time.monotonic_ns() if at_ns is None else at_ns
    assert type(now) is int and now > 0, now
    assert 0 <= end - start <= 5_000_000_000 and 0 <= now - end <= 5_000_000_000, row
    assert row['measurement_window_started_monotonic_ns'] < row['measurement_window_completed_monotonic_ns'], row
    assert any(ct['pool'] is None and ct['id'] == '[host]' for ct in row['containers']), row
    ranked = sorted(row['containers'], key=lambda ct: -ct['loadavg'][0])
    for name in names:
        ct, = [ct for ct in row['containers'] if ct['id'] == name]
        expected = identity(name) if expected_runs is None else expected_runs[name]
        assert ct['valid'] and [ct['init_pid'], ct['init_start_time_ticks']] == expected, ct
        assert ct['memory_limit'] and ct['memory'] / ct['memory_limit'] * 100 >= 1, ct
        assert ct['cpu_limit'] and ct['cpu_usage'] / ct['cpu_limit'] * 100 >= 10, ct
        assert ranked.index(ct) < 10, ranked


def check_record(record, names, expected_runs):
    # These are actual fixture clocks around the production call, not permit.time
    # (wall-clock metadata). The return clock bounds admission from above.
    entry, processed = record['observed_monotonic_ns'], record['processed_monotonic_ns']
    assert type(entry) is int and type(processed) is int, record
    assert 0 < entry <= processed <= time.monotonic_ns(), record
    assert record['event'] == 'controller' and record['accepted'], record
    check_raw(record['raw'], names, expected_runs, at_ns=entry)
    check_raw(record['raw'], names, expected_runs, at_ns=processed)


def guard(action, ct, run, success):
    result = subprocess.run(['osctl', 'ct', f'oomd-{action}', '--expected-init-pid', str(run[0]),
                             '--expected-init-start-time', str(run[1]), f'tank:{ct}'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    assert (result.returncode == 0) is success, result.stdout
    accepted = f'OOMd expected run accepted pid={run[0]} start={run[1]}'
    assert (accepted in result.stdout) is success, result.stdout
    return {'exit': result.returncode, 'output': result.stdout[-4096:]}


def sentinel(ct):
    assert command('osctl', 'ct', 'exec', ct, '/bin/busybox', 'cat', '/root/watchdog-sentinel') == f'{ct}:retained\n'


def lean_guard():
    containers = Containers(IDS[:1])
    stream = None
    try:
        containers.start()
        stream = Stream()
        first = stream.frame(containers.names)
        second = stream.frame(containers.names)
        ct = containers.names[0]
        old = identity(ct)
        rejected = guard('restart', ct, [old[0], old[1] + 1], success=False)
        assert identity(ct) == old
        missing = subprocess.run(['osctl', 'ct', 'oomd-stop', f'tank:{ct}'],
                                 capture_output=True, text=True, timeout=5)
        assert missing.returncode != 0 and identity(ct) == old
        sentinel(ct)
        stream.stop()
        stream = None
        restarted = guard('restart', ct, old, success=True)
        until(lambda: info(ct)['state'] == 'running', timeout=20)
        current = identity(ct)
        assert current != old
        sentinel(ct)
        old_rejected = guard('stop', ct, old, success=False)
        assert identity(ct) == current
        stopped = guard('stop', ct, current, success=True)
        until(lambda: info(ct)['state'] == 'stopped', timeout=20)
        assert not Path(f'/proc/{current[0]}').exists(), 'command success was not actual init EXIT'
        return {'first_raw': first, 'second_raw': second, 'stale_guard': rejected,
                'missing_guard_exit': missing.returncode, 'restart': restarted,
                'old_run_stop': old_rejected, 'stop': stopped, 'old_run': old, 'new_run': current}
    finally:
        if stream:
            stream.stop()
        containers.finish()


class Driver:
    def __init__(self, path):
        self.log = STATE / 'controller.log'
        self.output = self.log.open('w')
        self.process = subprocess.Popen(['rtnl-watchdog-policy-test', 'dispatch', str(path), 'disconnect-a'],
                                        stdout=self.output, stderr=subprocess.STDOUT, start_new_session=True)

    def records(self):
        assert self.process.poll() is None, self.log.read_text()[-8192:]
        result = []
        for line in self.log.read_text().splitlines():
            if line.startswith('{'):
                try:
                    result.append(json.loads(line))
                except json.JSONDecodeError:
                    pass  # The last regular-file write may be in progress.
        return result

    def stop(self):
        assert not any(r.get('status', {}).get('unknown_actions') for r in self.records()), \
            'unknown daemon effects not reconciled; retain fixture driver until guest teardown'
        self.process.send_signal(signal.SIGTERM)
        assert self.process.wait(timeout=30) == 0, self.log.read_text()[-8192:]
        self.output.close()


    def finish_reconciled_unknown(self):
        # Called only after both real runs and serialized daemon guard results
        # prove the remote effects finished. The product's unknown reservation
        # is intentionally retained; dispose only this isolated test driver and
        # its sampler, without claiming transport cancellation or freeing it.
        assert self.process.poll() is None and os.getpgid(self.process.pid) == self.process.pid
        os.killpg(self.process.pid, signal.SIGKILL)
        assert self.process.wait(timeout=5) == -signal.SIGKILL
        self.output.close()


def dispatch():
    containers = Containers(IDS)
    watchdog = held = writer = driver = None
    try:
        containers.start()
        runs = {ct: identity(ct) for ct in IDS}
        watchdog = Watchdog()
        watchdog.frame()
        driver = Driver(watchdog.state)
        # Real required reads establish same-run CPU baselines before distress.
        def warmed():
            rows = [r for r in driver.records() if r.get('accepted') and (r.get('raw') or {}).get('complete')]
            return rows[-2:] if len(rows) >= 2 else None
        warmup = until(warmed, timeout=10)
        for record in warmup:
            check_record(record, IDS, runs)
            assert not record['inflight'] and record['episode'] is None, record
        latest = next(r for r in reversed(driver.records()) if r.get('accepted') and
                      (r.get('raw') or {}).get('complete'))
        check_record(latest, IDS, runs)
        # Historical evidence cannot authorize the present hold/action phase.
        check_raw(latest['raw'], IDS, expected_runs=runs)
        held = holder()
        payload = Path(f'/proc/{runs[IDS[0]][0]}/cgroup').read_text().strip().split('::', 1)[1]
        def enter_payload():
            (CGROUP / payload.lstrip('/') / 'cgroup.procs').write_text(str(os.getpid()))
        writer = subprocess.Popen([sys.executable, '-c',
            "from pathlib import Path;Path('/proc/rtnl_monitor_fixture/call').write_text('lock 0\\n')"],
            preexec_fn=enter_payload)
        until(lambda: (row := slot(writer.pid)) and row[2:4] == ['1', '0'])
        distress = watchdog.frame(lambda r: r['state'] == 'distressed')
        def accepted_b():
            records = driver.records()
            text = driver.log.read_text()
            if not all(f'OOMd expected run accepted pid={run[0]} start={run[1]}' in text for run in runs.values()):
                return None
            latest = records[-1]
            if latest.get('event') != 'controller':
                return None
            return latest if (latest['status']['unknown_actions'] == 1 and
                              any(p['id'] == IDS[0] and p.get('unknown')
                                  for p in latest.get('inflight', []))) else None
        witness = until(accepted_b, timeout=6)
        assert held.poll() is None and slot(held.pid)[3] == '1'
        assert writer.poll() is None and slot(writer.pid)[2:4] == ['1', '0']
        # Independent daemon-side overlap evidence: this invalid-identity
        # command must fail on A's still-held manipulation lock BEFORE it can
        # check identity or mutate anything. A prior accepted progress or a
        # parked local worker alone cannot prove the daemon is still acting.
        overlap = guard('stop', IDS[0], [runs[IDS[0]][0], runs[IDS[0]][1] + 1], success=False)
        assert 'is held by ct_oomd_restart' in overlap['output'], overlap
        observed = [r for r in driver.records() if r.get('accepted') and r.get('episode')]
        assert len(observed) >= 2, observed
        assert all(r['restart_threshold'] == 2 for r in observed), observed
        episode_entry = next(r['observed_monotonic_ns'] for r in driver.records() if r.get('episode'))
        fresh = [r for r in observed if r['raw']['sample_started_monotonic_ns'] > episode_entry]
        assert len({(r['raw']['epoch'], r['raw']['sequence']) for r in fresh}) >= 2, fresh
        permits = {}
        for record in driver.records():
            for permit in record.get('inflight', []):
                permits.setdefault(permit['id'], permit)
        for ct in IDS:
            permit = permits[ct]
            assert permit['run'] == runs[ct] and permit['action'] == 'restart', permit
            assert permit['watchdog_episode'] == [distress['epoch'], distress['probe_sequence']], permit
            granted, = [r for r in fresh if (r['raw']['epoch'], r['raw']['sequence']) ==
                        (permit['epoch'], permit['sequence'])]
            # No fixture ct_show/hostname reads under the hold: compare the
            # real stream's pinned identities and required raw grant inputs.
            check_record(granted, IDS, runs)
            assert any(r['raw']['sequence'] < permit['sequence'] and
                       any(s['id'] == ct and s['restart'] == 1 for s in r['scores']) for r in fresh), fresh
        initial_tick = witness['observed_monotonic_ns']
        progressed = until(lambda: next((r for r in reversed(driver.records()) if
                           r.get('event') == 'controller' and
                           r['observed_monotonic_ns'] >= initial_tick + 400_000_000 and
                           any(p['id'] == IDS[0] and p.get('unknown') for p in r.get('inflight', []))), None), timeout=1)
        before_release = driver.log.read_text()
        for run in runs.values():
            assert before_release.count(f'OOMd expected run accepted pid={run[0]} start={run[1]}') == 1
        assert all(ct['stop'] == 0 for ct in progressed['scores']), progressed
        assert progressed['status']['unknown_actions'] == 1, progressed
        faults = [r for r in driver.records() if r.get('event') == 'transport_closed_after_guard']
        assert len(faults) == 1 and [faults[0]['pid'], faults[0]['start']] == runs[IDS[0]], faults
        exit_before_release = {ct: not Path(f'/proc/{run[0]}').exists() for ct, run in runs.items()}
        release()
        held.wait(timeout=3)
        writer.wait(timeout=3)
        until(lambda: all(info(ct)['state'] == 'running' and identity(ct) != runs[ct] for ct in IDS), timeout=25)
        reconciled = {ct: guard('stop', ct, runs[ct], success=False) for ct in IDS}
        assert all('no longer current' in row['output'] for row in reconciled.values()), reconciled
        def still_reserved():
            rows = [r for r in driver.records() if r.get('accepted') and r.get('raw', {}).get('complete') and
                    any(p['id'] == IDS[0] and p.get('unknown') for p in r.get('inflight', [])) and
                    r['raw']['sample_started_monotonic_ns'] > progressed['observed_monotonic_ns']]
            return rows[-2:] if len(rows) >= 2 else None
        retained = until(still_reserved, timeout=10)
        assert all(r['status']['unknown_actions'] == 1 for r in retained), retained
        assert driver.log.read_text().count(f'tank:{IDS[0]} OOMd expected run accepted ') == 1
        driver.finish_reconciled_unknown()
        driver = None
        for ct in IDS:
            sentinel(ct)
        return {'raw_warmup': warmup, 'distress': distress, 'daemon_acceptance_before_release': witness,
                'continued_controller_tick': progressed, 'expected_runs': runs,
                'guarded_permits': permits,
                'daemon_serialization_before_release': overlap,
                'transport_fault': faults[0], 'retained_after_remote_completion': retained,
                'serialized_old_run_rejections': reconciled,
                'init_EXIT_before_release': exit_before_release,
                'actual_runs_after_release': {ct: identity(ct) for ct in IDS},
                'final_command_output': (STATE / 'controller.log').read_text()[-8192:]}
    finally:
        release()
        if held:
            held.wait(timeout=10)
        if writer:
            writer.wait(timeout=10)
        if driver:
            driver.stop()
        if watchdog:
            watchdog.stop()
        containers.finish()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('scenario', choices=('lean_guard', 'dispatch'))
    args = parser.parse_args()
    print(json.dumps({'scenario': args.scenario, 'result': globals()[args.scenario]()}, sort_keys=True))
