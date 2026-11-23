"""Derive and verify the exact Git transaction for kernel retirement."""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

CATALOG = 'os/packages/linux/catalog'
TESTS = 'tests/kernel-specific'
PACKAGES = 'os/packages/linux/kernel-specific'
BATCHES = 'os/livepatches/batches'
DOCS = 'docs/os/livepatches'
NAV = 'mkdocs.yml'
RANGES = {'legacy': 'os/livepatches/legacy', 'ebpf': 'os/livepatches/ebpf/owned'}
VERSION = r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}'
NAME = r'[A-Za-z0-9][A-Za-z0-9_.-]*'
ROOTS = (CATALOG, TESTS, PACKAGES, BATCHES, DOCS, *RANGES.values())


class TransactionError(ValueError):
    pass


def git(*args, data=None):
    return subprocess.check_output(['git', *args], input=data,
                                   env={**os.environ, 'GIT_NO_LAZY_FETCH': '1'})


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}', value):
        raise TransactionError('invalid commit SHA')
    return value


def clean_checkout(base):
    if (git('rev-parse', '--show-prefix') != b'\n'
            or git('rev-parse', 'HEAD').decode().strip() != sha(base)
            or git('status', '--porcelain', '--untracked-files=all')):
        raise TransactionError('requires a clean checkout at the expected commit, from its root')


def tree(commit):
    entries = {}
    for item in git('ls-tree', '-rz', sha(commit)).split(b'\0'):
        if item:
            meta, path = item.split(b'\t', 1)
            mode, _, oid = meta.decode('ascii').split()
            entries[os.fsdecode(path)] = mode, oid
    return entries


def under(entries, prefix):
    return {path for path in entries if path.startswith(prefix + '/')}


def guard_tree(entries):
    for path, (mode, _) in entries.items():
        if any(root == path or root.startswith(path + '/') or path.startswith(root + '/')
               for root in ROOTS) or path == NAV:
            if (mode not in ('100644', '100755')
                    or not all(re.fullmatch(NAME, component) for component in path.split('/'))):
                raise TransactionError('unsafe tracked path or path kind under a retention root')
    if NAV not in entries:
        raise TransactionError('missing tracked MkDocs navigation')


def groups(entries, prefix, pattern, *, scaffolding=(), marker=None):
    result = {}
    if prefix in entries:
        raise TransactionError(f'{prefix} is not a directory')
    for path in under(entries, prefix):
        name, slash, _ = path.removeprefix(prefix + '/').partition('/')
        if not slash and name in scaffolding:
            continue
        if not slash or not re.fullmatch(pattern, name):
            raise TransactionError(f'invalid ownership unit under {prefix}')
        result.setdefault(name, set()).add(path)
    if marker and any(f'{prefix}/{name}/{marker}' not in paths for name, paths in result.items()):
        raise TransactionError(f'missing registration under {prefix}')
    return result


def nav_line(key):
    return f"        - 'Linux {key}': 'os/livepatches/{key}.md'\n".encode('ascii')


def changes(base, evidence, eligible):
    entries = tree(base)
    guard_tree(entries)
    catalog = evidence['catalog']['kernels']
    if (under(entries, CATALOG) != {f'{CATALOG}/{key}.nix' for key in catalog}
            or any(not re.fullmatch(VERSION, key) for key in catalog)):
        raise TransactionError('Git catalog files do not match the evaluated canonical catalog')
    if (not isinstance(eligible, list) or any(not isinstance(key, str) for key in eligible)
            or eligible != sorted(set(eligible))):
        raise TransactionError('retirement keys must be unique and in canonical order')
    retiring = set(eligible)
    if (not retiring <= catalog.keys()
            or retiring & {evidence['catalog']['stableKernelVersion'], evidence['catalog']['unstableKernelVersion']}):
        raise TransactionError('invalid retirement set')
    delete = {f'{CATALOG}/{key}.nix' for key in retiring}
    for prefix, scaffolding, marker in (
        (TESTS, ('default.nix',), 'default.nix'),
        (PACKAGES, ('default.nix',), 'default.nix'),
        (BATCHES, ('default.nix',), None),
    ):
        units = groups(entries, prefix, VERSION, scaffolding=scaffolding, marker=marker)
        if units.keys() - catalog.keys():
            raise TransactionError(f'orphan registration under {prefix}')
        if prefix == TESTS and sorted(units) != evidence['testOwners']:
            raise TransactionError('tracked tests do not match the evaluated registrations')
        for key in retiring & units.keys():
            delete.update(units[key])
    batches = set(units)
    docs = under(entries, DOCS) - {f'{DOCS}/{name}.md' for name in ('process', 'template')}
    if docs != {f'{DOCS}/{key}.md' for key in batches}:
        raise TransactionError('release documents do not match batch owners')
    nav = git('cat-file', 'blob', entries[NAV][1])
    lines = nav.splitlines(keepends=True)
    known = {nav_line(key) for key in batches}
    if (any(lines.count(line) != 1 for line in known)
            or any(b'os/livepatches/' in line and line not in known
                   and b'os/livepatches/process.md' not in line
                   and b'os/livepatches/template.md' not in line for line in lines)):
        raise TransactionError('unexpected livepatch navigation')
    removed_lines = {nav_line(key) for key in retiring & batches}
    delete.update(f'{DOCS}/{key}.md' for key in retiring & batches)
    for kind, prefix in RANGES.items():
        units = groups(entries, prefix, NAME, marker='default.nix')
        matches = evidence['ranges'][kind]
        # eBPF's deploy inventory intentionally omits disabled and open-ended
        # owners. Preserve those tracked records; still require every mapped one.
        if matches.keys() - units.keys() or (kind != 'ebpf' and units.keys() - matches.keys()):
            raise TransactionError(f'tracked and evaluated {kind} owners differ')
        for name, targets in matches.items():
            if len(targets) != len(set(targets)) or set(targets) - catalog.keys():
                raise TransactionError(f'invalid {kind} target predicate result')
            if targets and set(targets) <= retiring:
                delete.update(units[name])
    return sorted(delete, key=os.fsencode), b''.join(line for line in lines if line not in removed_lines), bool(removed_lines)


def subject(key):
    return f'os: retire kernel {key}'


def apply(base, evidence, eligible):
    clean_checkout(base)
    if subprocess.run(['git', 'symbolic-ref', '-q', 'HEAD'], stdout=subprocess.DEVNULL).returncode != 1:
        raise TransactionError('apply requires a detached disposable checkout')
    changes(base, evidence, eligible)  # Validate the complete plan before editing.
    _, previous_nav, _ = changes(base, evidence, [])
    previous_delete = set()
    changed = set()
    for count, key in enumerate(eligible, 1):
        delete, nav, _ = changes(base, evidence, eligible[:count])
        step = [path for path in delete if path not in previous_delete]
        for path in step:
            Path(path).unlink()
        if nav != previous_nav:
            Path(NAV).write_bytes(nav)
            step.append(NAV)
        git('--literal-pathspecs', 'add', '--pathspec-from-file=-', '--pathspec-file-nul',
            data=b''.join(os.fsencode(path) + b'\0' for path in step))
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as message:
            message.write(f'{subject(key)}\n\n'
                          'The retention window has elapsed and the fleet reports no use.\n'
                          'Keep both default selectors and remove this version and its\n'
                          'payloads that no longer have a supported target.\n')
            message.flush()
            subprocess.run(['git', 'commit', '--quiet', '-F', message.name], check=True, stdout=sys.stderr)
        clean_checkout(git('rev-parse', 'HEAD').decode().strip())
        changed.update(step)
        previous_delete, previous_nav = set(delete), nav
    return sorted(changed, key=os.fsencode)


def verify_tree(base, candidate, evidence, eligible):
    changes(base, evidence, eligible)  # Validate order and the full deletion set.
    if not eligible:
        raise TransactionError('cannot verify an empty retirement series')
    original = tree(base)
    current = sha(candidate)
    for count in range(len(eligible), 0, -1):
        if current == base:
            raise TransactionError('retirement series is missing a commit')
        headers, _, message = git('cat-file', 'commit', current).partition(b'\n\n')
        parents = [line.removeprefix(b'parent ') for line in headers.splitlines() if line.startswith(b'parent ')]
        if len(parents) != 1 or (count == 1 and parents[0] != base.encode('ascii')):
            raise TransactionError('each retirement commit must have exactly its preceding commit or base as parent')
        key = eligible[count - 1]
        if message.split(b'\n', 1)[0] != subject(key).encode('ascii'):
            raise TransactionError('unexpected retirement commit subject or order')
        delete, nav, nav_changed = changes(base, evidence, eligible[:count])
        expected = original.copy()
        for path in delete:
            del expected[path]
        if nav_changed:
            expected[NAV] = original[NAV][0], git('hash-object', '--stdin', data=nav).decode().strip()
        if tree(current) != expected:
            raise TransactionError(f'{key}: retirement commit contains an unexpected Git tree diff')
        current = sha(parents[0].decode('ascii'))
    return git('rev-parse', f'{candidate}^{{tree}}').decode().strip()


def snapshot(commit, *, full=False):
    source = f'''builtins.getFlake ("git+file://" + toString ./. + "?rev={sha(commit)}")'''
    expression = '''
      let
        f = SOURCE;
        inherit (f.inputs.nixpkgs) lib;
        inherit (f.lib) kernelVersions;
        system = "x86_64-linux";
        root = f.outPath;
        pkgs = f.inputs.nixpkgs.legacyPackages.${system};
        normalize = value:
          if builtins.isPath value then {
            path = lib.removePrefix (toString root + "/") (toString value);
            sha256 = builtins.hashFile "sha256" value;
          } else if builtins.isAttrs value then builtins.mapAttrs (_: normalize) value
          else if builtins.isList value then map normalize value
          else value;
        owners = import (root + "/tests/kernel-specific") { inherit lib; };
        ownerTests = key: owner:
          let helper = f.lib.testFramework.makeTestLib {
            inherit lib system;
            pkgs = f.nixpkgsPath;
            suitePath = root + "/tests/kernel-specific/${key}/suite";
            suiteArgs = {};
            testConfig = {};
            configuration = null;
          }; in builtins.attrNames (helper.makeTests (owner.runnerTests or []));
        bootFor = options: (f.lib.vpsadminosSystem {
          inherit system;
          modules = [ (root + "/os/configs/qemu.nix") options ];
        }).config.boot;
        tuple = key: zfsBuiltin:
          let boot = bootFor { boot = { kernelVersion = key; inherit zfsBuiltin; }; };
          in {
            kernel = boot.kernelPackage.drvPath;
            zfsUser = boot.zfsUserPackage.drvPath;
            zfsModule = if zfsBuiltin then boot.zfsBuiltinPkg.drvPath else boot.kernelPackages.zfs.drvPath;
          };
      in {
        catalog = normalize f.lib.availableKernels;
        testOwners = builtins.attrNames owners;
        ranges = import (root + "/os/livepatches/retention.nix") { inherit lib kernelVersions; };
      } EXTRA
    '''.replace('SOURCE', source).replace('EXTRA', ''' // {
        runner = builtins.attrNames f.testsMeta.${system};
        runnerOwners = builtins.mapAttrs ownerTests owners;
        checks = builtins.attrNames f.checks.${system};
        checkOwners = builtins.mapAttrs (_: owner:
          if owner ? checks then builtins.attrNames (owner.checks { inherit pkgs; }) else []) owners;
        ci = builtins.filter (lib.hasPrefix "ci-toplevel-kernel-") (builtins.attrNames f.packages.${system});
        tuples = lib.genAttrs kernelVersions (key: map (tuple key) [ true false ]);
        defaults = map (enableUnstable: (bootFor { system.vpsadminos = { inherit enableUnstable; }; }).kernelVersion)
          [ false true ];
        qualification = f.livepatchQualification.${system};
      }''' if full else '')
    return json.loads(subprocess.check_output([
        'nix', 'eval', '--offline', '--no-write-lock-file', '--impure', '--json',
        '--option', 'allow-import-from-derivation', 'false', '--expr', expression,
    ]))


def verify_evidence(before, after, eligible, batch_checks):
    retiring = set(eligible)
    expected_catalog = dict(before['catalog'])
    expected_catalog['kernels'] = {key: value for key, value in before['catalog']['kernels'].items()
                                   if key not in retiring}
    expected_tuples = {key: value for key, value in before['tuples'].items() if key not in retiring}
    if (expected_catalog != after['catalog'] or after['tuples'] != expected_tuples
            or before['defaults'] != after['defaults']
            or after['defaults'] != [after['catalog']['stableKernelVersion'], after['catalog']['unstableKernelVersion']]):
        raise TransactionError('candidate did not preserve the exact retained kernel/ZFS tuples and selectors')
    if set(after['testOwners']) != set(before['testOwners']) - retiring:
        raise TransactionError('candidate did not preserve the expected test registrations')
    for kind in RANGES:
        expected = {name: [key for key in targets if key not in retiring]
                    for name, targets in before['ranges'][kind].items()
                    if not targets or set(targets) - retiring}
        if expected != after['ranges'][kind]:
            raise TransactionError(f'candidate did not preserve the expected {kind} deploy predicates')
    ci_name = lambda key: 'ci-toplevel-kernel-' + key.replace('.', '_')
    if set(after['ci']) != set(before['ci']) - {ci_name(key) for key in retiring}:
        raise TransactionError('candidate kernel CI names do not match the remaining catalog')
    removed_tests = {name for key in retiring for name in before['runnerOwners'].get(key, [])}
    removed_checks = batch_checks | {name for key in retiring for name in before['checkOwners'].get(key, [])}
    for kind, removed in (('runner', removed_tests), ('checks', removed_checks)):
        if (not after[kind] or not removed <= set(before[kind])
                or set(after[kind]) != set(before[kind]) - removed):
            raise TransactionError(f'unexpected candidate {kind} enumeration')
    # Discover validates schema/roll-up integrity separately. Compare the exact
    # retained release and row identities, not revision-specific plan metadata.
    old, new = before['qualification'], after['qualification']
    releases = [release for release in old['releases'] if release['kernelVersion'] not in retiring]
    sets = {entry['id'] for entry in old['sets'] if entry['kernelVersion'] not in retiring}
    rows = {row['rowId'] for row in old['rows'] if row['setId'] in sets}
    if (new['releases'] != releases or {entry['id'] for entry in new['sets']} != sets
            or {row['rowId'] for row in new['rows']} != rows):
        raise TransactionError('candidate livepatch qualification does not match the retained releases')


def removed_batch_checks(base, eligible):
    result = set()
    for path in under(tree(base), BATCHES):
        match = re.fullmatch(rf'{BATCHES}/({VERSION})/([1-9][0-9]*)/qualification/check\.nix', path)
        if match and match[1] in eligible:
            result.add('livepatch-qualification-' + f'{match[1]}.{match[2]}'.replace('.', '_'))
    return result


def binding(candidate, tree_id, evidence):
    payload = json.dumps(evidence, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return {'candidate': sha(candidate), 'tree': tree_id, 'evidence': hashlib.sha256(payload).hexdigest()}
