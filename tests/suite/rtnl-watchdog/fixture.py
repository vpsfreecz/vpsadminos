#!/usr/bin/env python3
"""Production watchdog and caller-context holder in a disposable guest only."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request

CONTROL = Path('/proc/rtnl_monitor_fixture')
STATE = Path('/run/rtnl-watchdog-test')
BINARY = '/run/current-system/sw/bin/rtnl-watchdog'
METRIC_PREFIX = 'rtnl_watchdog_'
FIELDS = {'schema', 'boot_id', 'epoch', 'sequence', 'observed_monotonic_ns',
          'probe_sequence', 'state', 'dispatch_monotonic_ns', 'started_monotonic_ns',
          'completed_monotonic_ns', 'last_duration_ns', 'expected_errno', 'error_code'}


def until(predicate, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError('condition timed out')


def command(*args, **kwargs):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, **kwargs)
    except subprocess.CalledProcessError as error:
        error.add_note('Captured command output:\n' + (error.output or '')[-4096:])
        raise


def release():
    (CONTROL / 'release').write_text('release\n')


def slot(pid):
    return next((row.split() for row in (CONTROL / 'status').read_text().splitlines()[1:]
                 if row.split()[0] == str(pid)), None)


def holder():
    process = subprocess.Popen([sys.executable, __file__, '--hold'])
    until(lambda: (row := slot(process.pid)) and row[2:4] == ['1', '1'])
    return process


def children(pid):
    try:
        return [int(value) for value in Path(f'/proc/{pid}/task/{pid}/children').read_text().split()]
    except FileNotFoundError:
        return []  # A supervised observer may exit between status and proc read.


def process_identity(pid):
    def start():
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        if fields[0] in ('Z', 'X', 'x'):
            raise ProcessLookupError(f'{pid} is exiting')
        return int(fields[19])
    first = start()
    executable = str(Path(f'/proc/{pid}/exe').resolve(strict=True))
    if start() != first or str(Path(f'/proc/{pid}/exe').resolve(strict=True)) != executable:
        raise ProcessLookupError(f'{pid} identity changed')
    return {'pid': pid, 'start_time_ticks': first, 'exe': executable}


def process_census(pids, roles):
    identities = []
    for pid in pids:
        try:
            identity = process_identity(pid)
            identity['role'] = roles.get(identity['exe'], 'unknown')
        except (OSError, ValueError, IndexError) as error:
            identity = {'pid': pid, 'error': repr(error)}
        identities.append(identity)
    return {'identities': identities,
            'complete': all(row.get('role', 'unknown') != 'unknown' for row in identities)}


def file_identity(path):
    stat = path.stat()
    return [stat.st_dev, stat.st_ino]


def private_helper():
    observer = Path(BINARY).resolve(strict=True)
    return str((observer.parents[1] / 'libexec/rtnl-watchdog-probe').resolve(strict=True))


def helper_descriptors(pid, lock):
    ipc = Path(f'/proc/{pid}/fd/0')
    inherited_lock = Path(f'/proc/{pid}/fd/1')
    assert stat.S_ISSOCK(ipc.stat().st_mode), ipc
    flags = next(line.split()[1] for line in Path(f'/proc/{pid}/fdinfo/0').read_text().splitlines()
                 if line.startswith('flags:'))
    assert int(flags, 8) & os.O_ACCMODE == os.O_RDWR, flags
    assert stat.S_ISREG(inherited_lock.stat().st_mode), inherited_lock
    assert file_identity(inherited_lock) == file_identity(lock)
    return {'ipc_fd0': file_identity(ipc), 'lock_fd1': file_identity(inherited_lock)}


def syscall_blocked(pid):
    # x86_64 sendmsg. Read syscall identity, not potentially blocking stacks.
    return Path(f'/proc/{pid}/syscall').read_text().split()[0] == '46'


def cpu_sample(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return {'utime_ticks': int(fields[11]), 'stime_ticks': int(fields[12]),
            'monotonic_ns': time.monotonic_ns()}


def memory_sample(pid):
    values = dict(line.split(':', 1) for line in Path(f'/proc/{pid}/status').read_text().splitlines()
                  if ':' in line)
    return {key: int(values[key].split()[0]) for key in ('VmRSS', 'VmHWM', 'RssAnon', 'RssFile')}


def read_state(path, fresh=True):
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return None
    assert len(raw) <= 4096 and not path.is_symlink(), path
    assert path.stat().st_uid == 0 and path.stat().st_mode & 0o777 == 0o600, path
    row = json.loads(raw)
    assert FIELDS <= row.keys() and row['schema'] == 1 and row['expected_errno'] == 22, row
    assert row['state'] in ('starting', 'pending', 'distressed', 'healthy', 'error'), row
    assert row['boot_id'] == Path('/proc/sys/kernel/random/boot_id').read_text().strip(), row
    if fresh:
        assert 0 <= time.monotonic_ns() - row['observed_monotonic_ns'] < 1_000_000_000, row
    if row['state'] == 'healthy':
        assert row['error_code'] == 0 and row['completed_monotonic_ns'] is not None, row
    if row['state'] == 'distressed':
        assert row['started_monotonic_ns'] is not None and row['completed_monotonic_ns'] is None, row
    return row


def scrape():
    try:
        with urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2) as response:
            text = response.read().decode()
    except (urllib.error.URLError, TimeoutError):
        return None
    values = {line.split()[0]: float(line.split()[1]) for line in text.splitlines()
              if line and not line.startswith('#')}
    assert values['node_textfile_scrape_error'] == 0, text
    return {key.removeprefix(METRIC_PREFIX): value for key, value in values.items()
            if key.startswith(METRIC_PREFIX)}


def histogram(values):
    assert all('{' not in key or key.startswith('response_duration_seconds_bucket{le=') for key in values), values
    buckets = [values[f'response_duration_seconds_bucket{{le="{bound}"}}']
               for bound in ('0.001', '0.01', '0.1', '0.5', '1', '5', '10', '+Inf')]
    assert buckets == sorted(buckets) and buckets[-1] == values['response_duration_seconds_count'], values
    return values['response_duration_seconds_count'] - values['response_duration_seconds_bucket{le="1"}']


class Watchdog:
    def __init__(self, *extra, state=None, metrics=None, lock=None, prefix=()):
        STATE.mkdir(exist_ok=True)
        self.state = state or STATE / 'state.json'
        self.metrics = metrics or STATE / 'metrics.prom'
        self.lock = lock or STATE / 'lifetime.lock'
        self.errors = (STATE / 'stderr').open('w+')
        self.process = subprocess.Popen([*prefix, BINARY,
            '--state-file', str(self.state), '--metrics-file', str(self.metrics),
            '--lock-file', str(self.lock), *extra], stdout=subprocess.PIPE, stderr=self.errors)
        fcntl.fcntl(self.process.stdout, fcntl.F_SETPIPE_SZ, 4096)
        os.set_blocking(self.process.stdout.fileno(), False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.output = b''
        self.last = None

    def pump(self):
        if self.selector.select(0):
            self.output = (self.output + os.read(self.process.stdout.fileno(), 65536))[-16384:]

    def running(self):
        code = self.process.poll()
        if code is not None:
            self.errors.flush()
            raise AssertionError({'exit': code, 'state': self.last,
                                  'stderr': self.errors.name and Path(self.errors.name).read_text()[-4096:],
                                  'output': self.output.decode(errors='replace')})

    def frame(self, predicate=lambda row: row['state'] == 'healthy', timeout=5):
        previous = self.last
        def match():
            self.pump()
            self.running()
            row = read_state(self.state)
            if not row or previous and row['epoch'] == previous['epoch'] and row['sequence'] <= previous['sequence']:
                return None
            if predicate(row):
                self.last = row
                return row
            return None
        try:
            return until(match, timeout)
        except AssertionError as error:
            error.add_note(f'last accepted={self.last!r}, current={read_state(self.state)!r}')
            raise

    def helper(self):
        pids = children(self.process.pid)
        assert len(pids) == 1, pids
        assert process_identity(pids[0])['exe'] == private_helper()
        helper_descriptors(pids[0], self.lock)
        return pids[0]

    def stop(self):
        helpers = children(self.process.pid)
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        self.process.wait(timeout=12)
        # Closing IPC is asynchronous. Wait for known helper exit before the
        # next case reuses the lifetime-lock path; never cancel a pending call.
        until(lambda: all(not Path(f'/proc/{pid}').exists() for pid in helpers), timeout=5)
        self.pump()
        self.selector.close()
        self.process.stdout.close()
        self.errors.close()


def startup():
    watchdog = Watchdog()
    try:
        frame = watchdog.frame()
        child = watchdog.helper()
        assert child > 1
        until(watchdog.metrics.is_file)
        until(lambda: scrape() is not None)
        return {'healthy_expected_EINVAL': frame, 'helper': process_identity(child),
                'descriptors': helper_descriptors(child, watchdog.lock)}
    finally:
        watchdog.stop()
        assert not watchdog.state.exists() and not watchdog.metrics.exists()
        assert watchdog.lock.is_file(), 'lifetime lock must never be unlinked'


def pending(first_probe=False):
    watchdog = None
    held = None
    try:
        if not first_probe:
            watchdog = Watchdog(metrics=Path('/run/metrics/watchdog-test.prom'))
            watchdog.frame()
        baseline = until(lambda: (values if (values := scrape()) and values.get('available') == 1 else None)) if watchdog else None
        held = holder()
        if watchdog is None:
            watchdog = Watchdog(metrics=Path('/run/metrics/watchdog-test.prom'))
        distress = watchdog.frame(lambda r: r['state'] == 'distressed')
        child = watchdog.helper()
        until(lambda: syscall_blocked(child))
        assert held.poll() is None and slot(held.pid)[3] == '1'
        later = watchdog.frame(lambda r: r['state'] == 'distressed' and
                                r['sequence'] >= distress['sequence'] + 4)
        assert later['epoch'] == distress['epoch'] and later['probe_sequence'] == distress['probe_sequence']
        assert watchdog.helper() == child and syscall_blocked(child)
        assert later['started_monotonic_ns'] == distress['started_monotonic_ns']
        blocked_metrics = until(lambda: (values if (values := scrape()) and values.get('distress') == 1 and
                                        values.get('pending_age_seconds', 0) >= 1 else None))
        assert blocked_metrics['available'] == 1
        assert time.time() - blocked_metrics['snapshot_timestamp_seconds'] < 1
        histogram(blocked_metrics)
        if first_probe:
            assert blocked_metrics['response_duration_seconds_count'] == 0, blocked_metrics
        else:
            assert blocked_metrics['overdue_probes_total'] == baseline['overdue_probes_total'] + 1
            assert blocked_metrics['snapshot_timestamp_seconds'] > baseline['snapshot_timestamp_seconds']
        assert syscall_blocked(child) and held.poll() is None and slot(held.pid)[3] == '1'
        release()
        assert held.wait(timeout=3) == 0
        recovered = watchdog.frame(lambda r: r['state'] == 'healthy' and
                                    r['probe_sequence'] == distress['probe_sequence'])
        assert recovered['epoch'] == distress['epoch'] and recovered['last_duration_ns'] >= 1_000_000_000
        # Leave a consumer scrape gap through completion and a subsequent
        # fast request: the last-duration gauge may already hide the stall.
        fast = watchdog.frame(lambda r: r['state'] == 'healthy' and r['probe_sequence'] > recovered['probe_sequence'] and
                              r['last_duration_ns'] < 1_000_000_000)
        retained = until(lambda: (values if (values := scrape()) and values.get('response_duration_seconds_count', 0) >
                                 blocked_metrics['response_duration_seconds_count'] + 1 else None))
        assert histogram(retained) >= histogram(blocked_metrics) + 1
        assert retained['overdue_probes_total'] == blocked_metrics['overdue_probes_total']
        assert retained['response_duration_seconds_sum'] >= blocked_metrics['response_duration_seconds_sum'] + 1
        assert retained['last_probe_duration_seconds'] < 1, retained
        return {'distress_while_send_blocked': later, 'helper_pid': child,
                'matched_recovery': recovered, 'later_fast_probe': fast, 'first_probe': first_probe,
                'standalone_http_metrics': {'blocked': blocked_metrics, 'retained_after_fast_probe': retained}}
    finally:
        release()
        if held:
            held.wait(timeout=10)
        if watchdog:
            watchdog.stop()


def namespace():
    watchdog = Watchdog(prefix=('unshare', '--net'))
    try:
        row = watchdog.frame(lambda r: r['state'] == 'error' and r['error_code'] == 1)
        later = watchdog.frame(lambda r: r['state'] == 'error' and r['sequence'] >= row['sequence'] + 4)
        assert later['probe_sequence'] == row['probe_sequence'], 'namespace error bypassed backoff'
        assert later['started_monotonic_ns'] is None
        events = [json.loads(line) for line in watchdog.output.splitlines()]
        assert any(r.get('event') == 'error' and r['error_code'] == 1 for r in events), events
        assert not any(r.get('event') == 'healthy' for r in events), events
        return {'namespace_error': row, 'backoff': later, 'helper_pid': watchdog.helper(),
                'structured_status': events}
    finally:
        watchdog.stop()


def backpressure():
    watchdog = Watchdog()
    held = None
    try:
        initial = watchdog.frame()
        child = watchdog.helper()
        # Healthy output contains only bounded status transitions. Fill the
        # actual pipe to EAGAIN, then force a real distress transition while
        # leaving it undrained; no alternate healthy CLI is involved.
        writer = os.open(f'/proc/{watchdog.process.pid}/fd/1', os.O_WRONLY | os.O_NONBLOCK)
        filled = 0
        try:
            while True:
                filled += os.write(writer, b'x' * 4096)
        except BlockingIOError:
            pass
        finally:
            os.close(writer)
        assert filled > 0
        held = holder()
        distress = until(lambda: (row if (row := read_state(watchdog.state)) and row['state'] == 'distressed' else None))
        latest = until(lambda: (row if (row := read_state(watchdog.state)) and
                               row['sequence'] >= distress['sequence'] + 4 else None))
        assert latest['probe_sequence'] == distress['probe_sequence'] and latest['state'] == 'distressed'
        assert latest['epoch'] == initial['epoch'] and watchdog.helper() == child
        assert syscall_blocked(child) and held.poll() is None and slot(held.pid)[3] == '1'
        assert time.time() - watchdog.metrics.stat().st_mtime < 1
        metrics = watchdog.metrics.read_text()
        values = {line.split()[0]: float(line.split()[1]) for line in metrics.splitlines()
                  if line and not line.startswith('#')}
        assert values[METRIC_PREFIX + 'output_errors_total'] > 0, metrics
        release()
        assert held.wait(timeout=3) == 0
        recovered = watchdog.frame()
        return {'before': initial, 'filled_pipe_bytes': filled,
                'while_output_full': latest, 'metrics': metrics, 'after_drain': recovered}
    finally:
        release()
        if held:
            held.wait(timeout=10)
        watchdog.stop()


def supervisor():
    state = Path('/run/rtnl-watchdog.json')
    lock = Path('/run/rtnl-watchdog.lock')
    held = None
    recovered = None
    evidence = {'phase': 'startup'}
    def service_pid():
        text = command('sv', 'status', 'rtnl-watchdog')
        return int(text.split('(pid ')[1].split(')')[0]) if '(pid ' in text else None
    try:
        command('sv', 'start', 'rtnl-watchdog')
        initial = until(lambda: (row if (row := read_state(state)) and row['state'] == 'healthy' else None))
        parent = until(service_pid)
        original_child, = children(parent)
        observer_exe = str(Path(BINARY).resolve(strict=True))
        helper_exe = private_helper()
        original = process_identity(original_child)
        assert original['exe'] == helper_exe, original
        observer = process_identity(parent)
        assert observer['exe'] == observer_exe, observer
        lock_identity = file_identity(lock)
        descriptors = helper_descriptors(original_child, lock)
        service = Path('/etc/runit/services/rtnl-watchdog')
        assert not (service / 'finish').exists()
        run = (service / 'run').read_text()
        setup = [run.splitlines()[0].removeprefix('#!'), '/run/current-system/sw/bin/mkdir',
                 *re.findall(r'(?m)^(/nix/store/\S+/bin/mkdir)\s', run)]
        roles = {str(Path(path).resolve(strict=True)): 'setup' for path in setup}
        roles.update({observer_exe: 'observer', helper_exe: 'probe'})
        members = Path('/run/runit/cgroup.service/rtnl-watchdog/cgroup.procs')
        evidence.update(original_observer=observer, original_helper=original,
                        lifetime_lock=lock_identity, original_descriptors=descriptors)
        held = holder()
        distress = until(lambda: (row if (row := read_state(state)) and row['state'] == 'distressed' else None))
        until(lambda: syscall_blocked(original_child))
        os.kill(parent, signal.SIGKILL)
        # The real runit supervisor retries. All replacement observers must
        # fail the inherited lock. Generated wrappers may have mkdir children;
        # census actual executable identities across the whole service cgroup.
        end = time.monotonic() + 2
        complete_censuses = 0
        while time.monotonic() < end:
            evidence.update(phase='held', monotonic_ns=time.monotonic_ns(), holder=slot(held.pid))
            evidence['helper'] = process_identity(original_child)
            evidence['sendmsg_blocked'] = syscall_blocked(original_child)
            assert evidence['helper'] == original and evidence['sendmsg_blocked'], evidence
            evidence['current_lock'] = file_identity(lock)
            evidence['descriptors'] = helper_descriptors(original_child, lock)
            assert evidence['descriptors'] == descriptors, evidence
            assert evidence['current_lock'] == descriptors['lock_fd1'] == lock_identity, evidence
            pids = sorted({int(pid) for pid in members.read_text().split()})
            census = process_census(pids, roles)
            if sorted({int(pid) for pid in members.read_text().split()}) != pids:
                census['complete'] = False
                census['membership_changed'] = True
            evidence['census'] = census
            helpers = {row['pid'] for row in census['identities'] if row.get('role') == 'probe'}
            assert not helpers - {original_child}, evidence
            if census['complete']:
                assert helpers == {original_child}, evidence
                complete_censuses += 1
            time.sleep(0.05)
        assert complete_censuses >= 2 and evidence['census']['complete'], evidence
        assert held.poll() is None and slot(held.pid)[3] == '1'
        release()
        held.wait(timeout=3)
        recovered = until(lambda: (row if (row := read_state(state, fresh=False)) and row['state'] == 'healthy' and
                                   row['epoch'] != distress['epoch'] else None), timeout=8)
        new_parent = until(service_pid)
        new_child, = children(new_parent)
        assert new_child != original_child and file_identity(lock) == lock_identity
        assert process_identity(new_parent)['exe'] == observer_exe
        assert process_identity(new_child)['exe'] == helper_exe
        return {'initial': initial, 'orphan_distress': distress, 'orphan_helper': original_child,
                'replacement_helper': new_child, 'recovered': recovered,
                'held_identity_evidence': evidence, 'complete_censuses': complete_censuses}
    except Exception as error:
        error.add_note('Captured before RTNL cleanup: ' + json.dumps(evidence, sort_keys=True))
        raise
    finally:
        release()
        if held:
            held.wait(timeout=10)
        command('sv', 'stop', 'rtnl-watchdog')
        if recovered:
            until(lambda: not state.exists() and not Path('/run/metrics/rtnl-watchdog.prom').exists())


def overhead():
    watchdog = Watchdog()
    try:
        watchdog.frame()
        watchdog.frame()
        ticks = os.sysconf('SC_CLK_TCK')
        pids = [watchdog.process.pid, watchdog.helper()]
        memory_before = {pid: memory_sample(pid) for pid in pids}
        started = time.monotonic_ns()
        before = {pid: cpu_sample(pid) for pid in pids}
        responses = {}
        next_observation = started
        while time.monotonic_ns() - started < 10_000_000_000:
            watchdog.pump()
            watchdog.running()
            if time.monotonic_ns() >= next_observation:
                row = read_state(watchdog.state)
                if row and row['state'] == 'healthy' and row['completed_monotonic_ns'] >= started:
                    responses[(row['epoch'], row['probe_sequence'])] = row
                next_observation = time.monotonic_ns() + 250_000_000
            time.sleep(0.01)
        after = {pid: cpu_sample(pid) for pid in pids}
        ended = time.monotonic_ns()
        elapsed = (ended - started) / 1e9
        memory_after = {pid: memory_sample(pid) for pid in pids}
        total = sum(after[p]['utime_ticks'] + after[p]['stime_ticks'] -
                    before[p]['utime_ticks'] - before[p]['stime_ticks'] for p in pids)
        assert total >= 0 and watchdog.helper() == pids[1]
        assert responses and all(row['completed_monotonic_ns'] <= ended for row in responses.values()), responses
        frame = watchdog.frame()
        return {'defaults': {'interval_ms': 1000, 'threshold_ms': 1000, 'tick_ms': 250,
                             'error_backoff_ms': 5000},
                'before': before, 'after': after, 'wall_seconds': elapsed,
                'started_monotonic_ns': started, 'ended_monotonic_ns': ended,
                'memory_kib_before': memory_before, 'memory_kib_after': memory_after,
                'observed_completed_responses': list(responses.values()),
                'observer_executable': str(Path(BINARY).resolve(strict=True)),
                'helper_executable': private_helper(),
                'clock_ticks_per_second': ticks, 'cpu_ticks_delta': total,
                'cpu_seconds_delta': total / ticks, 'one_core_fraction': total / ticks / elapsed,
                'tick_seconds': 1 / ticks, 'zero_observed_delta_ticks': total == 0,
                'scope': 'Observer/helper utime+stime, including kernel time charged to them; '
                         'excludes exporter/oomd/sampler/daemon and other system work.',
                'final_state': frame}
    finally:
        watchdog.stop()


SCENARIOS = {'startup': startup, 'pending': pending,
             'first_probe': lambda: pending(first_probe=True), 'namespace': namespace,
             'backpressure': backpressure, 'supervisor': supervisor, 'overhead': overhead}


if __name__ == '__main__':
    if sys.argv[1:] == ['--hold']:
        (CONTROL / 'call').write_text('lock 9000\n')
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument('scenario', choices=SCENARIOS)
        args = parser.parse_args()
        print(json.dumps({'scenario': args.scenario, 'result': SCENARIOS[args.scenario]()}, sort_keys=True))
