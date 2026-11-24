import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import kernel_retention_transaction as txn


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous = Path.cwd()
        self.addCleanup(os.chdir, self.previous)
        os.chdir(self.tmp.name)
        self.git('init', '-q', '-b', 'staging')
        self.git('config', 'user.name', 'Offline fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'init.templateDir', '')
        self.catalog = {'stableKernelVersion': '6.12.118', 'unstableKernelVersion': '6.18.49',
                        'kernels': {k: {'dateAdded': '2026-01-01'}
                                    for k in ('6.12.110', '6.12.113', '6.12.118', '6.18.49')}}
        self.eligible = ['6.12.110', '6.12.113']
        self.evidence = {'catalog': self.catalog, 'testOwners': ['6.12.110'], 'ranges': {
            'legacy': {'private': ['6.12.110', '6.12.113'], 'orphan': []},
            'ebpf': {'shared': ['6.12.113', '6.12.118']},
        }}
        self.deletions = {
            f'{txn.CATALOG}/6.12.110.nix', f'{txn.CATALOG}/6.12.113.nix',
            f'{txn.TESTS}/6.12.110/default.nix', f'{txn.TESTS}/6.12.110/boot.nix',
            f'{txn.PACKAGES}/6.12.110/default.nix', f'{txn.PACKAGES}/6.12.110/private.patch',
            f'{txn.BATCHES}/6.12.110/1/default.nix', f'{txn.DOCS}/6.12.110.md',
            f'{txn.BATCHES}/6.12.113/1/default.nix', f'{txn.BATCHES}/6.12.113/1/a.patch',
            f'{txn.DOCS}/6.12.113.md',
            f'{txn.RANGES["legacy"]}/private/default.nix', f'{txn.RANGES["legacy"]}/private/one.patch',
        }
        remaining = {
            'unrelated.txt', f'{txn.CATALOG}/6.12.118.nix', f'{txn.CATALOG}/6.18.49.nix',
            f'{txn.TESTS}/default.nix', f'{txn.PACKAGES}/default.nix',
            f'{txn.BATCHES}/default.nix', f'{txn.DOCS}/process.md', f'{txn.DOCS}/template.md',
            f'{txn.RANGES["legacy"]}/orphan/default.nix', f'{txn.RANGES["ebpf"]}/shared/default.nix',
        }
        for path in self.deletions | remaining:
            self.write(path, b'fixture\n')
        self.nav = b'nav:\n        - Documentation\n'
        self.write(txn.NAV, self.nav + b''.join(map(txn.nav_line, self.eligible)))
        self.base = self.commit()
        self.git('switch', '--quiet', '--detach', self.base)

    @staticmethod
    def write(path, content):
        path = Path(path)
        path.parent.mkdir(exist_ok=True, parents=True)
        path.write_bytes(content)

    @staticmethod
    def git(*args):
        return txn.git(*args).decode().strip()

    def commit(self):
        self.git('add', '-A')
        message = Path(self.tmp.name) / '.git' / 'message'
        message.write_text('test: exercise tracked kernel retirement\n', encoding='utf-8')
        self.git('commit', '-q', '-F', str(message))
        return self.git('rev-parse', 'HEAD')

    def test_apply_proof_revert_and_noop(self):
        before = txn.tree(self.base)
        self.assertEqual(txn.apply(self.base, self.evidence, []), [])
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.base)
        for keys in (self.eligible[::-1], self.eligible + self.eligible[:1]):
            with self.assertRaisesRegex(txn.TransactionError, 'unique and in canonical order'):
                txn.apply(self.base, self.evidence, keys)
        self.assertEqual(self.git('status', '--porcelain'), '')

        changed = txn.apply(self.base, self.evidence, self.eligible)
        self.assertEqual(set(changed), self.deletions | {txn.NAV})
        self.assertEqual(Path(txn.NAV).read_bytes(), self.nav)
        candidate = self.git('rev-parse', 'HEAD')
        first = self.git('rev-parse', 'HEAD^')
        self.assertEqual(self.git('log', '--reverse', '--format=%s', f'{self.base}..{candidate}').splitlines(),
                         ['os: retire kernel 6.12.110', 'os: retire kernel 6.12.113'])
        self.assertEqual(self.git('rev-list', '--parents', '-n1', first), f'{first} {self.base}')
        self.assertEqual(self.git('rev-list', '--parents', '-n1', candidate), f'{candidate} {first}')
        self.assertEqual(txn.git('show', f'{first}:{txn.NAV}'), self.nav + txn.nav_line('6.12.113'))
        shared = f'{txn.RANGES["legacy"]}/private/default.nix'
        self.assertIn(shared, txn.tree(first))
        self.assertNotIn(shared, txn.tree(candidate))
        self.assertIn(f'{txn.RANGES["ebpf"]}/shared/default.nix', txn.tree(candidate))
        self.assertEqual(txn.verify_tree(self.base, candidate, self.evidence, self.eligible),
                         self.git('rev-parse', 'HEAD^{tree}'))
        self.assertEqual(set(before) - txn.tree(candidate).keys(), self.deletions)
        self.git('revert', '--no-edit', candidate, first)
        self.assertEqual(txn.tree(self.git('rev-parse', 'HEAD')), before)

    def test_single_retirement_reverts_independently(self):
        keys = self.eligible[:1]  # The other shared target remains selectable.
        txn.apply(self.base, self.evidence, keys)
        candidate = self.git('rev-parse', 'HEAD')
        self.assertEqual(txn.verify_tree(self.base, candidate, self.evidence, keys),
                         self.git('rev-parse', 'HEAD^{tree}'))
        self.git('revert', '--no-edit', candidate)
        self.assertEqual(txn.tree(self.git('rev-parse', 'HEAD')), txn.tree(self.base))

    def test_dirty_checkout_and_unexpected_diff_refuse(self):
        self.write('unrelated.txt', b'dirty\n')
        with self.assertRaisesRegex(txn.TransactionError, 'clean checkout'):
            txn.apply(self.base, self.evidence, self.eligible)
        self.git('restore', 'unrelated.txt')
        txn.apply(self.base, self.evidence, self.eligible)
        self.write('unrelated.txt', b'dirty\n')
        candidate = self.commit()
        with self.assertRaisesRegex(txn.TransactionError, 'unexpected retirement commit subject'):
            txn.verify_tree(self.base, candidate, self.evidence, self.eligible)

    def test_reject_invalid_chain_even_when_tip_tree_matches(self):
        script = Path(__file__).resolve().parents[1] / 'kernel-retention.py'
        txn.apply(self.base, self.evidence, self.eligible)
        tip_tree, first_tree = (self.git('rev-parse', rev) for rev in ('HEAD^{tree}', 'HEAD^^{tree}'))
        good_first = self.git('rev-parse', 'HEAD^')
        first, last = [txn.subject(key) for key in self.eligible]
        self.git('switch', '-q', '--detach', good_first)
        self.write('unrelated.txt', b'edited, then repaired by the final commit\n')
        self.git('add', '--', 'unrelated.txt')
        collateral_tree = self.git('write-tree')

        def commit(tree, subject, *parents):
            parent_args = [value for parent in parents for value in ('-p', parent)]
            return txn.git('commit-tree', '--no-gpg-sign', tree, *parent_args,
                           data=f'{subject}\n'.encode()).decode().strip()

        wrong_parent = commit(first_tree, first, good_first)
        wrong_subject = commit(first_tree, 'os: unrelated', self.base)
        wrong_order = commit(first_tree, last, self.base)
        edited = commit(collateral_tree, first, self.base)
        empty_step = commit(self.git('rev-parse', f'{self.base}^{{tree}}'), first, self.base)
        # Same final tree for each; only subjects, ancestry or prefix trees vary.
        examples = {
            'wrong parent': commit(tip_tree, last, wrong_parent),
            'wrong subject': commit(tip_tree, last, wrong_subject),
            'wrong order': commit(tip_tree, first, wrong_order),
            'merge': commit(tip_tree, last, good_first, self.base),
            'edited and repaired': commit(tip_tree, last, edited),
            'empty step': commit(tip_tree, last, empty_step),
            'missing step': commit(tip_tree, last, self.base),
        }
        evidence = {'base': self.evidence, 'report': {'base': self.base, 'eligible': self.eligible}}
        Path('.git/receipt').write_text(json.dumps(evidence))
        for reason, bad in examples.items():
            with self.subTest(reason=reason):
                self.assertEqual(self.git('rev-parse', f'{bad}^{{tree}}'), tip_tree)
                with self.assertRaises(txn.TransactionError):
                    txn.verify_tree(self.base, bad, self.evidence, self.eligible)
                Path('.git/proof').write_text(json.dumps(txn.binding(bad, tip_tree, evidence)))
                result = subprocess.run([sys.executable, '-B', str(script), 'verify-tree',
                                        '--base', self.base, '--candidate', bad,
                                        '--evidence', '.git/receipt', '--proof', '.git/proof'],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('retirement', result.stderr)

    def test_hook_rejection_aborts_before_artifact(self):
        hook = Path('.git/hooks/commit-msg')
        self.write(hook, b'#!/bin/sh\n! grep -q "^os: retire kernel 6.12.113$" "$1"\n')
        hook.chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError):
            txn.apply(self.base, self.evidence, self.eligible)
        self.assertEqual(self.git('log', '-1', '--format=%s'), 'os: retire kernel 6.12.110')
        self.assertEqual(self.git('for-each-ref', '--format=%(refname)'), 'refs/heads/staging')
        self.assertEqual(self.git('rev-parse', 'staging'), self.base)
        with self.assertRaises(txn.TransactionError):
            txn.verify_tree(self.base, self.git('rev-parse', 'HEAD'), self.evidence, self.eligible)

    def test_symlinks_unpaired_docs_and_orphan_units_refused(self):
        for path, operation, diagnostic in (
            (f'{txn.BATCHES}/6.12.113/1/escape', lambda p: p.symlink_to('/etc/passwd'), 'unsafe'),
            (f'{txn.DOCS}/6.19.0.md', lambda p: p.write_text('other\n'), 'documents'),
            (f'{txn.TESTS}/6.19.0/default.nix', lambda p: self.write(p, b'orphan\n'), 'orphan'),
            (f'{txn.CATALOG}/6.12.118', lambda p: p.write_text('not a record\n'), 'catalog files'),
        ):
            with self.subTest(path=path):
                operation(Path(path))
                invalid = self.commit()
                with self.assertRaisesRegex(txn.TransactionError, diagnostic):
                    txn.changes(invalid, self.evidence, self.eligible)
                self.git('restore', '--source', self.base, '--staged', '--worktree', '--', path)

    def test_ebpf_retirement_inventory_is_a_validated_subset(self):
        prefix = txn.RANGES['ebpf']
        disabled = f'{prefix}/disabled/default.nix'
        open_ended = f'{prefix}/open_ended/default.nix'
        retiring = f'{prefix}/retiring/default.nix'
        self.write(disabled, b'{ enable = false; kernelRanges = []; }\n')
        self.write(open_ended, b'{ enable = true; kernelRanges = [{ sinceKernel = "6.12.110"; }]; }\n')
        self.write(retiring, b'{ enable = true; kernelRanges = [{ sinceKernel = "6.12.110"; untilKernel = "6.12.111"; }]; }\n')
        self.base = self.commit()
        self.evidence['ranges']['ebpf']['retiring'] = ['6.12.110']
        self.assertEqual(set(txn.apply(self.base, self.evidence, self.eligible)), self.deletions | {txn.NAV, retiring})
        for keep in (disabled, open_ended, f'{prefix}/shared/default.nix'):
            self.assertTrue(Path(keep).is_file())

        broken = copy.deepcopy(self.evidence)
        broken['ranges']['ebpf']['missing'] = ['6.12.110']
        with self.assertRaisesRegex(txn.TransactionError, 'evaluated ebpf owners differ'):
            txn.changes(self.base, broken, self.eligible)
        # A tracked directory is not enough: it needs a regular owner record.
        self.git('switch', '-q', '--detach', self.base)
        Path(retiring).unlink()
        self.write(f'{prefix}/retiring/source.c', b'not an owner\n')
        malformed = self.commit()
        with self.assertRaisesRegex(txn.TransactionError, 'missing registration'):
            txn.changes(malformed, self.evidence, self.eligible)

    def test_ff_and_concurrent_or_rejected_write(self):
        remote = Path('.git') / 'fixture-remote'
        self.git('init', '--bare', '-q', str(remote))
        self.git('push', '-q', str(remote), self.base + ':refs/heads/staging')
        txn.apply(self.base, self.evidence, self.eligible)
        candidate = self.git('rev-parse', 'HEAD')
        self.git('push', '-q', str(remote), candidate + ':refs/heads/staging')
        self.git('switch', '--quiet', '--detach', self.base)
        self.write('unrelated.txt', b'concurrent\n')
        competing = self.commit()
        with self.assertRaises(subprocess.CalledProcessError):
            subprocess.run(['git', 'push', str(remote), competing + ':refs/heads/staging'],
                           check=True, capture_output=True)
        self.assertEqual(self.git('--git-dir', str(remote), 'rev-parse', 'staging'), candidate)
        # A rejecting remote cannot be treated as success or raced around.
        hook = remote / 'hooks' / 'pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        self.git('switch', '--quiet', '--detach', candidate)
        self.write('unrelated.txt', b'otherwise fast forward\n')
        descendant = self.commit()
        with self.assertRaises(subprocess.CalledProcessError):
            subprocess.run(['git', 'push', str(remote), descendant + ':refs/heads/staging'],
                           check=True, capture_output=True)
        self.assertEqual(self.git('--git-dir', str(remote), 'rev-parse', 'staging'), candidate)

    def test_recheck_refuses_new_in_use_release_and_unbound_proof(self):
        script = Path(__file__).resolve().parents[1] / 'kernel-retention.py'
        txn.apply(self.base, self.evidence, self.eligible)
        candidate = self.git('rev-parse', 'HEAD')
        receipt = {'base': self.evidence, 'report': {
            'base': self.base, 'eligible': self.eligible, 'fleet_count': 1, 'as_of': '2026-02-02T12:00:00Z',
        }}
        tree_id = txn.verify_tree(self.base, candidate, self.evidence, self.eligible)
        proof = txn.binding(candidate, tree_id, receipt)
        paths = Path('.git')
        for path, data in (('receipt', receipt), ('proof', proof)):
            (paths / path).write_text(json.dumps(data))
        node = {'fqdn': 'node.example.invalid', 'type': 'node', 'hypervisor_type': 'vpsadminos',
                'kernel': '6.12.118', 'status': True, 'last_report': '2026-02-02T12:01:00Z'}
        fleet = {'acquired_at': '2026-02-02T12:01:00Z', 'nodes': [node]}
        cmd = [sys.executable, '-B', str(script), 'recheck', '--base', self.base, '--candidate', candidate,
               '--evidence', str(paths / 'receipt'), '--proof', str(paths / 'proof'),
               '--as-of', '2026-02-02T12:01:00Z', '--fleet', str(paths / 'fleet')]

        def run():
            (paths / 'fleet').write_text(json.dumps(fleet))
            return subprocess.run(cmd, capture_output=True, text=True)

        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['fresh_until_ms'], 1770033780000)
        node['last_report'] = '2026-02-02T11:58:59Z'
        self.assertIn('stale or future status report', run().stderr)
        node['last_report'] = fleet['acquired_at']
        node['fqdn'] = 'replacement.example.invalid'
        self.assertEqual(run().returncode, 0)
        fleet['nodes'].append({**node, 'fqdn': 'new.example.invalid'})
        self.assertIn('eligibility or row count differs', run().stderr)
        fleet['nodes'].pop()
        node['kernel'] = '6.12.110.1'
        self.assertIn('eligibility or row count differs', run().stderr)
        node['kernel'] = '6.12.118'
        earlier = '2026-02-02T12:00:00Z'
        fleet['acquired_at'] = node['last_report'] = earlier
        self.assertIn('second collection is not newer', run().stderr)
        proof['tree'] = '0' * 40
        (paths / 'proof').write_text(json.dumps(proof))
        self.assertIn('offline verification proof', run().stderr)

    def test_prepare_collects_and_reports_without_write_opt_in(self):
        source = Path(__file__).resolve().parents[2]
        for path in ('tools/kernel-retention.py', 'tools/kernel_retention_transaction.py'):
            self.write(path, (source / path).read_bytes())
        self.base = self.commit()
        runner = Path.cwd() / '.git'
        stubs = runner / 'bin'
        self.write(runner / 'snapshot.json', json.dumps(self.evidence).encode())
        self.write(stubs / 'nix', b'#!/bin/sh\nexec cat "$RUNNER_TEMP/snapshot.json"\n')
        self.write(stubs / 'curl', b'''#!/usr/bin/env bash
printf '{"status":true,"response":{"nodes":[{"fqdn":"node.example.invalid","type":"node","hypervisor_type":"vpsadminos","kernel":"6.12.118","status":true,"last_report":"%s"}]}}\\n200\\n\\n' "$(date -u +%FT%T.%6NZ)"
''')
        for stub in stubs.iterdir():
            stub.chmod(0o755)
        env = {**os.environ, 'PATH': str(stubs) + ':' + os.environ['PATH'],
               'RUNNER_TEMP': str(runner), 'GITHUB_OUTPUT': str(runner / 'output')}
        env.pop('KERNEL_RETENTION_WRITE', None)
        prepare = source / '.github/workflows/scripts/kernel-retention-prepare.sh'
        result = subprocess.run(['bash', prepare], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['eligible'], self.eligible)
        out = runner / 'kernel-retention'
        self.assertEqual([path.name for path in out.iterdir()], ['evidence.json'])
        evidence = (out / 'evidence.json').read_text()
        self.assertEqual(set(json.loads(evidence)), {'base', 'report'})
        self.assertNotIn('example.invalid', evidence + result.stdout + result.stderr)
        self.assertFalse((runner / 'output').exists())
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.base)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_publisher_checks_exact_sha_before_staging(self):
        source = Path(__file__).resolve().parents[2]
        for path in ('tools/kernel-retention.py', 'tools/kernel_retention_transaction.py'):
            self.write(path, (source / path).read_bytes())
        self.base = self.commit()
        runner = Path.cwd() / '.git'
        output = runner / 'kernel-retention'
        output.mkdir()

        def make_artifact(base):
            txn.apply(base, self.evidence, self.eligible)
            candidate = self.git('rev-parse', 'HEAD')
            bundle = output / 'candidate.bundle'
            bundle.unlink(missing_ok=True)
            self.git('bundle', 'create', str(bundle), 'HEAD', '^' + self.base)
            report = {'base': base, 'eligible': self.eligible, 'fleet_count': 1,
                      'as_of': '2026-02-02T12:00:00Z'}
            evidence = {'base': self.evidence, 'report': report}
            proof = txn.binding(candidate, txn.verify_tree(base, candidate, self.evidence, self.eligible), evidence)
            for name, value in (('evidence', evidence), ('proof', proof)):
                (output / (name + '.json')).write_text(json.dumps(value))
            self.git('switch', '--quiet', '--detach', self.base)
            return candidate
        stubs = runner / 'bin'
        stubs.mkdir()
        self.write(stubs / 'git', b'''#!/usr/bin/env bash
args=()
for arg; do
  case "$arg" in
    "$CANDIDATE:refs/heads/staging") printf '%s\\n' "$CANDIDATE" >> "$STAGING_PUSHES"; args+=("$arg");;
    https://github.com/vpsfreecz/vpsadminos.git) args+=("$LOCAL_REMOTE");;
    *://*) exit 99;;
    *) args+=("$arg");;
  esac
done
exec "$REAL_GIT" "${args[@]}"
''')
        self.write(stubs / 'gh', b'''#!/usr/bin/env bash
case "$*" in
  */dispatches*) ;;
  */kernel-entry-check.yml/runs*) printf '{"workflow_runs":[{"id":1,"head_sha":"%s","head_branch":"kernel-retention-candidate-99-%s","head_repository":{"full_name":"vpsfreecz/vpsadminos"},"event":"workflow_dispatch","status":"completed","conclusion":"success"}]}' "$CANDIDATE" "$GITHUB_RUN_ATTEMPT";;
  */actions/runs/1/jobs) printf '{"jobs":[{"name":"kernel-entry-correctness","conclusion":"success","check_run_url":"https://example.invalid/2"}]}';;
  */check-runs/2)
    if [[ -n ${MOVE_TIP:-} ]]; then
      "$REAL_GIT" --git-dir "$LOCAL_REMOTE" update-ref refs/heads/staging "$MOVE_TIP" "$BASE" || exit 99
    fi
    printf '{"head_sha":"%s","name":"kernel-entry-correctness","app":{"slug":"github-actions"},"status":"completed","conclusion":"success"}' "$CHECK_SHA";;
  *) exit 99;;
esac
''')
        # Use the real collector's fixture mode so its acquisition time and
        # the synthetic report share the same fixed clock as the publisher.
        self.write(stubs / 'python3', b'''#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ge 3 && "$1 $2 $3" == '-B tools/kernel-retention.py collect' ]]; then
  fixture="$RUNNER_TEMP/public-status.json"
  printf '{"status":true,"response":{"nodes":[{"fqdn":"node.example.invalid","type":"node","hypervisor_type":"vpsadminos","kernel":"%s","status":true,"last_report":"2026-02-02T12:00:20Z"}]}}\\n' "${IN_USE:-6.12.118}" > "$fixture"
  set -- "$@" --fixture "$fixture" --acquired-at 2026-02-02T12:00:30Z
fi
exec "$REAL_PYTHON" "$@"
''')
        self.write(stubs / 'curl', b'#!/bin/sh\nexit 99\n')
        self.write(stubs / 'date', b'''#!/usr/bin/env bash
case "$*" in
  '-u +%FT%T.%6NZ') printf '%s\\n' 2026-02-02T12:00:31.000000Z;;
  '-u +%s%3N')
    # Move only the final check beyond the report's 12:02:20 deadline.
    if [[ ${EXPIRE_RECHECK:-} == yes ]]; then
      printf '%s\\n' 1770033741000  # 12:02:21 UTC
    else
      printf '%s\\n' 1770033632000  # 12:00:32 UTC
    fi;;
  *) exit 99;;
esac
''')
        for stub in stubs.iterdir():
            stub.chmod(0o755)
        remote = runner / 'publisher-remote'
        self.git('init', '--bare', '-q', str(remote))
        self.git('push', '-q', str(remote), self.base + ':refs/heads/staging')
        pushes = runner / 'staging-pushes'
        env = {**os.environ, 'PATH': str(stubs) + ':' + os.environ['PATH'], 'REAL_GIT': shutil.which('git'),
               'LOCAL_REMOTE': str(remote), 'BASE': self.base, 'STAGING_PUSHES': str(pushes),
               'GITHUB_REPOSITORY': 'vpsfreecz/vpsadminos', 'GITHUB_REF': 'refs/heads/staging',
               'GITHUB_RUN_ID': '99', 'KERNEL_RETENTION_WRITE': 'true',
               'RUNNER_TEMP': str(runner), 'REAL_PYTHON': sys.executable}
        publisher = source / '.github/workflows/scripts/kernel-retention-publish.sh'

        def publish(candidate, attempt, check, **scenario):
            return subprocess.run(['bash', publisher], env={**env, 'CANDIDATE': candidate, 'CHECK_SHA': check,
                                  'GITHUB_RUN_ATTEMPT': attempt, **scenario},
                                  capture_output=True, text=True, timeout=10)

        # This artifact, checksum and diff all agree on a different parent.
        # A plain FF to it could still succeed, smuggling the extra commit in.
        wrong_base = txn.git('commit-tree', '--no-gpg-sign', f'{self.base}^{{tree}}', '-p', self.base,
                             data=b'test: extra commit\n').decode().strip()
        self.git('switch', '-q', '--detach', wrong_base)
        descendant = make_artifact(wrong_base)
        result = publish(descendant, '1', descendant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match the expected base', result.stderr)
        receipt = output / 'evidence.json'
        evidence = json.loads(receipt.read_text())
        evidence['report']['base'] = self.base
        receipt.write_text(json.dumps(evidence))
        result = publish(descendant, '2', descendant)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('preceding commit or base as parent', result.stderr)
        self.assertEqual(self.git('--git-dir', str(remote), 'for-each-ref', '--format=%(refname)'), 'refs/heads/staging')
        self.assertEqual(self.git('--git-dir', str(remote), 'rev-parse', 'staging'), self.base)

        candidate = make_artifact(self.base)
        self.git('push', '-q', str(remote), wrong_base + ':refs/heads/competing-fixture')
        for attempt, check, options, diagnostic in (
            ('3', self.base, {}, ''),
            ('4', candidate, {'EXPIRE_RECHECK': 'yes'}, 'expired before the staging push'),
            ('5', candidate, {'IN_USE': '6.12.110.1'}, 'eligibility or row count differs'),
            ('6', candidate, {'KERNEL_RETENTION_WRITE': 'false'}, ''),
            ('7', candidate, {'MOVE_TIP': wrong_base}, ''),
        ):
            with self.subTest(attempt=attempt):
                result = publish(candidate, attempt, check, **options)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(self.git('--git-dir', str(remote), 'rev-parse', 'staging'),
                                 options.get('MOVE_TIP', self.base))
                self.assertFalse(pushes.exists())
        self.git('--git-dir', str(remote), 'update-ref', 'refs/heads/staging', self.base, wrong_base)
        result = publish(candidate, '8', candidate)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('--git-dir', str(remote), 'rev-parse', 'staging'), candidate)
        self.assertEqual(pushes.read_text().splitlines(), [candidate])

    def test_evaluated_retained_tuple_must_not_change(self):
        before = copy.deepcopy(self.evidence)
        before.update(runner=['stable', 'private'], checks=['generic', 'batch-check'],
                      runnerOwners={'6.12.110': ['private']}, checkOwners={},
                      ci=['ci-toplevel-kernel-' + k.replace('.', '_') for k in self.catalog['kernels']],
                      defaults=['6.12.118', '6.18.49'],
                      tuples={k: 'drv' for k in self.catalog['kernels']},
                      qualification={'sets': [], 'rows': [], 'releases': []})
        after = copy.deepcopy(before)
        for key in self.eligible:
            del after['catalog']['kernels'][key]
            del after['tuples'][key]
            after['ci'].remove('ci-toplevel-kernel-' + key.replace('.', '_'))
        after['testOwners'] = []
        after['runner'] = ['stable']
        after['checks'] = ['generic']
        after['ranges'] = {'legacy': {'orphan': []}, 'ebpf': {'shared': ['6.12.118']}}
        txn.verify_evidence(before, after, self.eligible, {'batch-check'})
        after['runner'] = ['unrelated']
        with self.assertRaisesRegex(txn.TransactionError, 'runner enumeration'):
            txn.verify_evidence(before, after, self.eligible, {'batch-check'})
        after['catalog']['kernels']['6.12.118']['rev'] = 'different'
        with self.assertRaisesRegex(txn.TransactionError, 'retained kernel/ZFS tuples'):
            txn.verify_evidence(before, after, self.eligible, {'batch-check'})
