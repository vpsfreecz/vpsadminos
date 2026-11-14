#!/usr/bin/env python3
"""Actual common Top stream, guarded daemon and two-slot action witnesses."""
import argparse
from contextlib import contextmanager
from functools import wraps
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time
import threading

sys.dont_write_bytecode = True
from fixture import STATE, Watchdog, command as fixture_command, cpu_sample, holder, memory_sample, release, slot, until

CGROUP = Path('/sys/fs/cgroup')
IDS = ('watchdog-a', 'watchdog-b')
# Retain 4 MiB in the init shell so the real memory predicate remains eligible
# while leaving room for the Ruby attach runner inside the container's limit.
BALLAST = ('ballast=xxxxxxxxxxxxxxxx\nballast_steps=0\n'
           'while [ "$ballast_steps" -lt 18 ]; do\n'
           '  ballast="$ballast$ballast"; ballast_steps=$((ballast_steps + 1))\n'
           'done\n')


# Only lean_guard enables these fixture diagnostics. They never share its JSON
# stdout, change command deadlines, or establish remote completion.
DIAGNOSTICS = None


class Diagnostics:
    def __init__(self, path, snapshot_after=90):
        self.path = Path(path)
        self.started = time.monotonic_ns()
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.current = {}
        self.known = {}
        self.runs = {}
        self.unknown = False
        self.truncated = False
        self.path.open('x').close()
        self.timer = threading.Timer(snapshot_after, self.snapshot)
        self.timer.daemon = True
        self.timer.start()

    def emit(self, phase, edge, *, primary=None, **fields):
        try:
            self._publish(phase, edge, **fields)
        except Exception as error:
            if primary is None:
                raise
            primary.add_note('Diagnostic publication also failed: ' + repr(error))

    def _publish(self, phase, edge, **fields):
        now = time.monotonic_ns()
        row = {'phase': phase, 'edge': edge, 'monotonic_ns': now,
               'elapsed_ns': now - self.started, 'runtime_pid': os.getpid(),
               'runs': dict(self.runs), **fields}
        data = (json.dumps(row, sort_keys=True) + '\n').encode()
        if len(data) > 3500:
            row = {**row, 'record_truncated': True}
            row.pop('command', None)
            row['error'] = str(row.get('error', ''))[:1024]
            data = (json.dumps(row, sort_keys=True) + '\n').encode()
        with self.lock:
            self.current = row
            latest = self.path.with_suffix('.current.json')
            temporary = latest.with_suffix('.tmp')
            temporary.write_bytes(data)
            temporary.replace(latest)
            with self.path.open('ab') as output:
                if output.tell() + len(data) <= 60 * 1024 - 512:
                    output.write(data)
                elif not self.truncated:
                    output.write(b'{"truncated":true,"latest":"see current.json"}\n')
                    self.truncated = True

    def track(self, process, kind):
        row = {'pid': process.pid, 'command': process.args, 'kind': kind}
        try:
            row['start_ticks'] = Path(f'/proc/{process.pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
        except OSError as error:
            row['identity_error'] = repr(error)
        with self.lock:
            self.known[process.pid] = row
        self.emit(kind, 'spawned', **row)

    def snapshot(self):
        if self.done.is_set():
            return
        # Copy publication state, then release the lock before any process or
        # daemon read. The main command path never waits for collection.
        deadline = time.monotonic() + 2
        with self.lock:
            current, runs = dict(self.current), dict(self.runs)
            known = [dict(row) for row in self.known.values() if 'terminal_status' not in row]
        path = self.path.with_suffix('.snapshot.jsonl')
        remaining = 256 * 1024

        def save(edge, **fields):
            nonlocal remaining
            row = {'edge': edge, 'monotonic_ns': time.monotonic_ns(), **fields}
            data = (json.dumps(row, sort_keys=True) + '\n').encode()
            if len(data) > remaining - 256:
                data = b'{"truncated":true,"collection_incomplete":true}\n'
            if len(data) <= remaining:
                with path.open('ab') as output:
                    output.write(data)
                remaining -= len(data)

        try:
            save('begin', current=current, known=known, runs=runs, runtime_pid=os.getpid())
            for row in [{'pid': os.getpid(), 'kind': 'runtime'}, *known]:
                if time.monotonic() >= deadline:
                    save('process_failed', collection_incomplete=True, error='collection deadline')
                    break
                evidence = {}
                for name in ('stat', 'status', 'wchan', 'syscall', 'cmdline'):
                    try:
                        with Path(f'/proc/{row["pid"]}/{name}').open('rb') as source:
                            evidence[name] = source.read(4096).decode(errors='replace')
                    except OSError as error:
                        evidence[name] = {'unavailable': repr(error)}
                try:
                    start = evidence['stat'].rsplit(')', 1)[1].split()[19]
                    identity_current = start == row.get('start_ticks', start)
                except (AttributeError, IndexError):
                    identity_current = None
                save('process', identity=row, identity_current=identity_current, evidence=evidence)
            if time.monotonic() >= deadline:
                save('failed', collection_incomplete=True, error='deadline before daemon diagnostic')
                return
            argv = ['osctl', 'debug', 'threads', 'ls']
            save('debug_begin', command=argv)
            process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            save('debug_spawned', pid=process.pid, command=argv)
            output = bytearray()
            truncated = False
            with selectors.DefaultSelector() as selector:
                os.set_blocking(process.stdout.fileno(), False)
                selector.register(process.stdout, selectors.EVENT_READ)
                eof = False
                while time.monotonic() < deadline and not eof:
                    for _, _ in selector.select(min(0.02, max(0, deadline - time.monotonic()))):
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            eof = True
                            break
                        capacity = max(0, min(48 * 1024, remaining // 4) - len(output))
                        output.extend(chunk[:capacity])
                        truncated |= len(chunk) > capacity
                timed_out = not eof or process.poll() is None
                if timed_out:
                    process.terminate()
                try:
                    status = process.wait(timeout=max(0, deadline - time.monotonic()) if not timed_out else 1)
                except subprocess.TimeoutExpired:
                    status = None  # Unreaped read-only client; retain PID, never replace it.
                save('debug_failed' if timed_out or status != 0 else 'debug_returned',
                     pid=process.pid, status=status, timed_out=timed_out,
                     remote_completion='unknown' if timed_out else 'client_returned',
                     output=output.decode(errors='replace'), output_truncated=truncated)
            process.stdout.close()
            save('returned', collection_incomplete=timed_out or status != 0 or truncated)
        except Exception as error:
            save('failed', error=repr(error), collection_incomplete=True)

    def close(self):
        self.done.set()
        self.timer.cancel()


@contextmanager
def phase(name):
    if DIAGNOSTICS:
        DIAGNOSTICS.emit(name, 'begin')
    try:
        yield
    except BaseException as error:
        if DIAGNOSTICS:
            DIAGNOSTICS.emit(name, 'failed', primary=error, error=repr(error))
        raise
    else:
        if DIAGNOSTICS:
            DIAGNOSTICS.emit(name, 'returned')


def traced_phase(function):
    @wraps(function)
    def call(*args, **kwargs):
        with phase(function.__qualname__):
            return function(*args, **kwargs)
    return call


def run_command(args, **kwargs):
    if not DIAGNOSTICS:
        return subprocess.run(args, **kwargs)
    timeout = kwargs.pop('timeout', None)
    check = kwargs.pop('check', False)
    if kwargs.pop('capture_output', False):
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with phase('command'):
        DIAGNOSTICS.emit('command', 'begin', command=args, timeout=timeout)
        process = subprocess.Popen(args, **kwargs)
        primary = None
        try:
            # Publication after spawn is inside the child/uncertainty boundary.
            DIAGNOSTICS.track(process, 'command')
            stdout, stderr = process.communicate(timeout=timeout)
            result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
            with DIAGNOSTICS.lock:
                DIAGNOSTICS.known[process.pid]['terminal_status'] = result.returncode
            if check:
                if result.returncode and args[0] == 'osctl' and 'ct' in args:
                    DIAGNOSTICS.unknown = True
                # Establish the command failure/output before publishing it.
                try:
                    result.check_returncode()
                except subprocess.CalledProcessError as error:
                    DIAGNOSTICS.emit('command', 'returned', primary=error, pid=process.pid,
                                     command=args, status=result.returncode)
                    raise
            DIAGNOSTICS.emit('command', 'returned', pid=process.pid, command=args, status=result.returncode)
            return result
        except BaseException as error:
            primary = error
            DIAGNOSTICS.unknown |= args[0] == 'osctl' and 'ct' in args
            # Never let a second file error skip local child accounting. This
            # bounded wait cannot prove remote daemon cancellation/completion.
            try:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=1)
            except Exception as child_error:
                error.add_note(f'Local client {process.pid} cleanup also failed: {child_error!r}')
            DIAGNOSTICS.emit('command', 'failed', primary=error, pid=process.pid, command=args,
                             error=repr(error), status=process.poll(), remote_completion='unknown')
            raise
        finally:
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe is None:
                    continue
                try:
                    pipe.close()
                except Exception as error:
                    if primary is None:
                        DIAGNOSTICS.unknown |= args[0] == 'osctl' and 'ct' in args
                        raise
                    primary.add_note('Local client pipe close also failed: ' + repr(error))


def command(*args, **kwargs):
    if not DIAGNOSTICS:
        return fixture_command(*args, **kwargs)
    try:
        return run_command(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, check=True, **kwargs).stdout
    except subprocess.CalledProcessError as error:
        error.add_note('Captured command output:\n' + (error.output or '')[-4096:])
        raise


@traced_phase
def info(ct):
    return json.loads(command('osctl', '-j', 'ct', 'show', ct))


@traced_phase
def identity(ct):
    row = info(ct)
    pid = row['init_pid']
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    assert info(ct)['init_pid'] == pid
    run = [pid, int(fields[19])]
    if DIAGNOSTICS:
        with DIAGNOSTICS.lock:
            DIAGNOSTICS.runs[ct] = run
        DIAGNOSTICS.emit('identity', 'returned', ct=ct, run=run)
    return run


class Containers:
    def __init__(self, names):
        self.names = names
        self.created = []

    @traced_phase
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

    @traced_phase
    def finish(self):
        for ct in reversed(self.created):
            if info(ct)['state'] == 'running':
                command('osctl', 'ct', 'stop', '--kill', ct, timeout=30)
            command('osctl', 'ct', 'del', '--prune', ct, timeout=30)


class Stream:
    def __init__(self, *, optional_collectors=False):
        STATE.mkdir(exist_ok=True)
        self.stderr = (STATE / 'top.stderr').open('w+', errors='replace')
        self.collectors = {'netif': optional_collectors, 'zfs': optional_collectors, 'iostat': False}
        flags = [] if optional_collectors else ['--no-netif', '--no-zfs']
        self.process = subprocess.Popen(['osctl', '-j', 'ct', 'top', '--rate', '1',
                                        *flags, '--no-iostat', '--no-processes'],
                                        stdout=subprocess.PIPE, stderr=self.stderr)
        if DIAGNOSTICS:
            DIAGNOSTICS.track(self.process, 'sampler')
        os.set_blocking(self.process.stdout.fileno(), False)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b''
        self.last = None

    def read(self, names, expected_runs=None):
        assert self.process.poll() is None, {'exit': self.process.returncode, 'last_frame': self.last,
                                            'stderr': Path(self.stderr.name).read_text(errors='replace')[-4096:]}
        if self.selector.select(0):
            self.buffer += os.read(self.process.stdout.fileno(), 65536)
        while b'\n' in self.buffer:
            line, self.buffer = self.buffer.split(b'\n', 1)
            row = json.loads(line)
            previous = self.last
            if previous:
                assert row['epoch'] == previous['epoch'] and row['sequence'] > previous['sequence'], row
            self.last = row
            if row['complete']:
                check_raw(row, names, expected_runs, collectors=self.collectors)
                if previous and previous['complete'] and row['sequence'] == previous['sequence'] + 1:
                    assert row['measurement_window_started_monotonic_ns'] == previous['sample_started_monotonic_ns'], row
                return row
        return None

    def frame(self, names, expected_runs=None):
        try:
            return until(lambda: self.read(names, expected_runs), timeout=10)
        except Exception as error:
            self.stderr.flush()
            self.stderr.seek(0, os.SEEK_END)
            self.stderr.seek(max(0, self.stderr.tell() - 4096))
            error.add_note(json.dumps({'pid': self.process.pid, 'exit': self.process.poll(),
                                       'last_frame': self.last,
                                       'stdout_tail': self.buffer[-4096:].decode(errors='replace'),
                                       'stderr': self.stderr.read()[-4096:]}, sort_keys=True))
            raise

    @traced_phase
    def stop(self):
        if DIAGNOSTICS:
            DIAGNOSTICS.emit('sampler-stop', 'begin', pid=self.process.pid, status=self.process.poll())
        self.process.terminate()
        if DIAGNOSTICS:
            DIAGNOSTICS.emit('sampler-wait', 'begin', pid=self.process.pid, status=self.process.poll(), timeout=5)
        self.process.wait(timeout=5)
        if DIAGNOSTICS:
            with DIAGNOSTICS.lock:
                DIAGNOSTICS.known[self.process.pid]['terminal_status'] = self.process.returncode
            DIAGNOSTICS.emit('sampler-stop', 'returned', pid=self.process.pid, status=self.process.poll())
        self.selector.close()
        self.process.stdout.close()
        self.stderr.close()


def check_raw(row, names, expected_runs=None, *, at_ns=None, collectors=None):
    assert type(row['top_schema']) is int and row['top_schema'] == 1 and row['complete'] is True, row
    expected_collectors = collectors or {'netif': False, 'zfs': False, 'iostat': False}
    assert row['collectors'] == expected_collectors and all(type(v) is bool for v in row['collectors'].values()), row
    start, end = row['sample_started_monotonic_ns'], row['sample_completed_monotonic_ns']
    now = time.monotonic_ns() if at_ns is None else at_ns
    assert type(now) is int and now > 0, now
    assert 0 <= end - start <= 5_000_000_000 and 0 <= now - end <= 5_000_000_000, row
    window_start, window_end = row['measurement_window_started_monotonic_ns'], row['measurement_window_completed_monotonic_ns']
    assert 0 < window_start < start <= end == window_end and window_end - window_start <= 6_000_000_000, row
    if not expected_collectors['zfs']:
        assert row['zfs'] is None, row
    else:
        assert isinstance(row['zfs'], dict) and isinstance(row['zfs']['arcstats'], dict), row
        assert row['zfs']['iostat'] is None, row
    for ct in row['containers']:
        if not expected_collectors['netif']:
            assert ct['tx'] is None and ct['rx'] is None, ct
        else:
            assert isinstance(ct['tx'], dict) and isinstance(ct['rx'], dict), ct
        if not expected_collectors['zfs']:
            assert ct['zfsio'] is None, ct
        else:
            assert isinstance(ct['zfsio'], dict), ct
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


@traced_phase
def guard(action, ct, run, success):
    result = run_command(['osctl', 'ct', f'oomd-{action}', '--expected-init-pid', str(run[0]),
                             '--expected-init-start-time', str(run[1]), f'tank:{ct}'],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    if success and result.returncode and DIAGNOSTICS:
        DIAGNOSTICS.unknown = True
    try:
        assert (result.returncode == 0) is success, result.stdout
    except AssertionError as error:
        if DIAGNOSTICS:
            DIAGNOSTICS.emit('guard', 'failed', primary=error, command=result.args,
                             status=result.returncode, remote_completion='unknown')
        raise
    accepted = f'OOMd expected run accepted pid={run[0]} start={run[1]}'
    assert (accepted in result.stdout) is success, result.stdout
    return {'exit': result.returncode, 'output': result.stdout[-4096:]}


@traced_phase
def sentinel(ct):
    assert command('osctl', 'ct', 'exec', ct, '/bin/busybox', 'cat', '/root/watchdog-sentinel') == f'{ct}:retained\n'


@traced_phase
def top_cost(stream, names, expected_runs):
    if DIAGNOSTICS:
        DIAGNOSTICS.emit('top_cost', 'begin', collectors=stream.collectors, pid=stream.process.pid)
    warmup = [stream.frame(names, expected_runs), stream.frame(names, expected_runs)]
    pid = stream.process.pid
    memory_before = memory_sample(pid)
    ticks = os.sysconf('SC_CLK_TCK')
    started = time.monotonic_ns()
    before = cpu_sample(pid)
    samples = []
    while time.monotonic_ns() - started < 10_000_000_000:
        row = stream.read(names, expected_runs)
        if row:
            samples.append({**{key: row[key] for key in
                               ('epoch', 'sequence', 'sample_started_monotonic_ns', 'sample_completed_monotonic_ns',
                                'measurement_window_started_monotonic_ns', 'measurement_window_completed_monotonic_ns',
                                'complete', 'invalid_reason', 'collectors')},
                            'observed_monotonic_ns': time.monotonic_ns(),
                            'snapshot_duration_ns': row['sample_completed_monotonic_ns'] - row['sample_started_monotonic_ns']})
        time.sleep(0.01)
    after = cpu_sample(pid)
    ended = time.monotonic_ns()
    memory_after = memory_sample(pid)
    total = after['utime_ticks'] + after['stime_ticks'] - before['utime_ticks'] - before['stime_ticks']
    assert samples and total >= 0 and stream.process.poll() is None
    return {'collectors': stream.collectors, 'command': stream.process.args, 'sampler_pid': pid,
            'sampler_executable': str(Path(f'/proc/{pid}/exe').resolve(strict=True)),
            'warmup': warmup, 'samples': samples,
            'sample_count': len(samples), 'before': before, 'after': after,
            'started_monotonic_ns': started, 'ended_monotonic_ns': ended,
            'wall_seconds': (ended - started) / 1e9, 'clock_ticks_per_second': ticks,
            'cpu_ticks_delta': total, 'cpu_seconds_delta': total / ticks, 'tick_seconds': 1 / ticks,
            'memory_kib_before': memory_before, 'memory_kib_after': memory_after,
            'scope': 'Common Top own-process CPU/RSS and acquired snapshot durations at rate 1; '
                     'iostat/processes disabled in both windows. Excludes daemon/exporter/controller '
                     'and other system work; not full-default-Top or node cost.'}


def _lean_guard():
    containers = Containers(IDS[:1])
    stream = None
    try:
        containers.start()
        ct = containers.names[0]
        old = identity(ct)
        stream = Stream(optional_collectors=True)
        enabled_cost = top_cost(stream, containers.names, {ct: old})
        stream.stop()
        stream = None
        stream = Stream()
        disabled_cost = top_cost(stream, containers.names, {ct: old})
        first, second = disabled_cost['warmup']
        rejected = guard('restart', ct, [old[0], old[1] + 1], success=False)
        assert identity(ct) == old
        missing = run_command(['osctl', 'ct', 'oomd-stop', f'tank:{ct}'],
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
        return {'first_raw': first, 'second_raw': second, 'top_cost_windows': [enabled_cost, disabled_cost],
                'stale_guard': rejected,
                'missing_guard_exit': missing.returncode, 'restart': restarted,
                'old_run_stop': old_rejected, 'stop': stopped, 'old_run': old, 'new_run': current}
    finally:
        original = sys.exc_info()[1]
        if DIAGNOSTICS and DIAGNOSTICS.unknown:
            unresolved = original or RuntimeError('No further CT cleanup after unknown command effects')
            DIAGNOSTICS.emit('cleanup', 'failed', primary=unresolved, remote_completion='unknown',
                             error='No further CT cleanup after unknown command effects')
            if original is None:
                raise unresolved
        else:
            try:
                with phase('cleanup'):
                    if stream:
                        stream.stop()
                    containers.finish()
            except Exception as error:
                if original is None:
                    raise
                original.add_note('Cleanup also failed: ' + repr(error))


def lean_guard():
    global DIAGNOSTICS
    path = os.environ.get('RTNL_WATCHDOG_DIAGNOSTICS',
                          f'/run/osvm/shared-dir/rtnl-watchdog-{os.getpid()}-{time.monotonic_ns()}.jsonl')
    DIAGNOSTICS = Diagnostics(path)
    try:
        with phase('lean_guard'):
            return _lean_guard()
    finally:
        DIAGNOSTICS.close()
        DIAGNOSTICS = None


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
