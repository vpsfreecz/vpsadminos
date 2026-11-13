#!/usr/bin/env python3
"""Exercise the installed adapter/client/Ruby/runit path with one real CT."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

CT = 'rtnl-smoke'
ROOTS = Path('/run/osctl-rtnl-monitor/roots.json')
METRICS = Path('/run/metrics/osctl-rtnl-monitor.prom')
SERVICES = ('osctl-rtnl-monitor-roots', 'osctl-rtnl-monitor')


def command(*args, timeout=30):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.CalledProcessError as error:
        error.add_note('Captured command output (last 4096 characters):\n' + (error.output or '')[-4096:])
        raise


def until(predicate, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError('service/inventory readiness timed out')


def ct_info():
    return json.loads(command('osctl', '-j', 'ct', 'show', CT))


def service_pid(name):
    try:
        command('sv', 'check', name)
    except subprocess.CalledProcessError:
        return None
    status = command('sv', 'status', name)
    match = re.search(r'\(pid (\d+)\)', status)
    assert match, status
    return int(match.group(1))


def manifest():
    try:
        value = json.loads(ROOTS.read_text())
    except FileNotFoundError:
        return None
    if value.get('schema') != 1 or len(value.get('roots', [])) != 1:
        return None
    return value


def metric_values():
    try:
        return {line.split()[0]: float(line.split()[1]) for line in METRICS.read_text().splitlines()
                if line and not line.startswith('#') and '{' not in line}
    except FileNotFoundError:
        return {}


def recent_snapshot(after_ns):
    log = Path('/var/log/osctl-rtnl-monitor/current')
    if not log.exists():
        return None
    for line in reversed(log.read_text().splitlines()):
        offset = line.find('{')  # svlogd's timestamp precedes the NDJSON record.
        if offset < 0:
            continue
        try:
            row = json.loads(line[offset:])
        except json.JSONDecodeError:
            continue
        if (row.get('type') == 'snapshot' and row.get('monotonic_ns', 0) >= after_ns
                and row.get('available') is True and row.get('assessment_valid') is True):
            return row
    return None


def main():
    created = False
    try:
        command('osctl', 'ct', 'new', '--skip-image', '--distribution', 'alpine',
                '--version', 'latest', '--arch', 'x86_64', CT)
        created = True
        command('osctl', 'ct', 'unset', 'start-menu', CT)
        command('osctl', 'ct', 'mount', CT)
        rootfs = Path(ct_info()['rootfs'])
        for name in ('bin', 'sbin', 'etc/network', 'proc', 'sys', 'dev', 'root', 'tmp', 'run', 'var'):
            (rootfs / name).mkdir(parents=True, exist_ok=True)
        shutil.copyfile('/etc/rtnl-monitor-smoke-busybox', rootfs / 'bin/busybox')
        (rootfs / 'bin/busybox').chmod(0o555)
        (rootfs / 'bin/sh').symlink_to('busybox')
        shutil.copyfile('/etc/rtnl-monitor-smoke-init', rootfs / 'sbin/rtnl-smoke-init')
        (rootfs / 'sbin/rtnl-smoke-init').chmod(0o555)
        command('osctl', 'ct', 'set', 'init-cmd', CT, '/sbin/rtnl-smoke-init')
        command('osctl', 'ct', 'start', CT)
        info = until(lambda: (row if (row := ct_info())['state'] == 'running' and row['init_pid'] else None))
        assert info['group_path'].endswith('/user-owned'), info
        expected_root = info['group_path'].removesuffix('/user-owned')
        init_membership = Path(f"/proc/{info['init_pid']}/cgroup").read_text()
        assert f'0::/{expected_root}/' in init_membership, init_membership

        started_ns = time.monotonic_ns()
        # Use generated runit scripts and the installed wrapper unchanged. No
        # manual interpreter, GEM_PATH or fake daemon response is introduced.
        for name in SERVICES:
            command('sv', 'start', name)
        first = until(manifest)
        assert ROOTS.stat().st_mode & 0o777 == 0o600
        assert ROOTS.stat().st_uid == 0
        root = first['roots'][0]
        assert (root['pool'], root['id'], root['path']) == (info['pool'], CT, expected_root), first
        assert isinstance(root['run_token'], str) and root['run_token'], first
        assert first['generated_monotonic_ns'] >= started_ns
        assert Path(first['cgroup_mount'], expected_root).is_dir()
        pids = {name: until(lambda name=name: service_pid(name)) for name in SERVICES}
        frame = until(lambda: recent_snapshot(started_ns))
        assert frame['schema'] == 1 and frame['owner_supported'] is False, frame
        assert frame['coverage'] == 'global_blocking_wrappers_v1', frame
        metrics = until(lambda: (row if (row := metric_values()).get('osctl_rtnl_monitor_available') == 1
                                and row.get('osctl_rtnl_monitor_assessment_valid') == 1 else None))
        stamp = metrics['osctl_rtnl_monitor_snapshot_timestamp_seconds']
        second = until(lambda: (row if (row := manifest()) and row['generated_monotonic_ns'] >
                                first['generated_monotonic_ns'] else None))
        assert second['roots'] == first['roots'], (first, second)
        assert ct_info()['init_pid'] == info['init_pid']
        fresh = until(lambda: (row if (row := metric_values()).get(
            'osctl_rtnl_monitor_snapshot_timestamp_seconds', 0) > stamp else None))
        assert {name: service_pid(name) for name in SERVICES} == pids
        print(json.dumps({'real_container': CT, 'init_pid': info['init_pid'],
                          'base_cgroup_path': expected_root, 'roots': first,
                          'next_heartbeat_ns': second['generated_monotonic_ns'],
                          'snapshot': frame, 'metrics': fresh, 'service_pids': pids}, sort_keys=True))
    finally:
        for name in reversed(SERVICES):
            command('sv', 'stop', name)
        until(lambda: not ROOTS.exists() and not METRICS.exists())
        if created:
            if ct_info()['state'] == 'running':
                command('osctl', 'ct', 'stop', '--kill', CT)
            command('osctl', 'ct', 'del', '--prune', CT)


if __name__ == '__main__':
    main()
