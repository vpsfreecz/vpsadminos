#!/usr/bin/env python3
"""Collect fleet evidence, plan retention, or verify a disposable retirement."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

PUBLIC_STATUS = 'https://api.vpsfree.cz/v7.0/nodes/public_status'
MAX_BYTES = 2 * 1024 * 1024
FRESHNESS = timedelta(seconds=120)
MINIMUM_AGE = timedelta(days=30)
CATALOG_KEY = r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}'
RELEASE = re.compile(rf'({CATALOG_KEY})(?:\.[1-9][0-9]*)?')
LABEL = re.compile(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?')
INSTANT = re.compile(
    r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
    r'(?:\.[0-9]{1,6})?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])'
)
ROW_FIELDS = {'fqdn', 'type', 'hypervisor_type', 'status', 'kernel', 'last_report'}
CATALOG_FIELDS = {'stableKernelVersion', 'unstableKernelVersion', 'kernels'}


class RetentionError(ValueError):
    """A safe diagnostic: never interpolate untrusted response values."""


def matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value)


def json_input(raw):
    def unique_object(items):
        result = dict(items)
        if len(result) != len(items):
            raise RetentionError('JSON input contains duplicate fields')
        return result

    def invalid_constant(_value):
        raise RetentionError('JSON input contains a non-JSON number')

    if len(raw) > MAX_BYTES:
        raise RetentionError('JSON input exceeds the size limit')
    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                          parse_constant=invalid_constant)
    except RetentionError:
        raise
    except (ValueError, RecursionError):
        raise RetentionError('invalid UTF-8 JSON input') from None


def read_json(path):
    with path.open('rb') as stream:
        return json_input(stream.read(MAX_BYTES + 1))


def instant(value, *, utc=False):
    if not matches(INSTANT, value) or (utc and not value.endswith(('Z', '+00:00'))):
        raise RetentionError('expected an explicit timestamp' + (' in UTC' if utc else ' with offset'))
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise RetentionError('invalid calendar timestamp') from None


def utc_text(value):
    return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def day(value):
    if not matches(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', value):
        raise RetentionError('expected a YYYY-MM-DD retention date')
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise RetentionError('invalid Gregorian retention date') from None


def canonical_name(value):
    if not isinstance(value, str):
        raise RetentionError('fleet contains an invalid host identity')
    name = value.removesuffix('.')
    labels = name.split('.')
    if len(name) > 253 or len(labels) < 2 or not all(matches(LABEL, label) for label in labels):
        raise RetentionError('fleet contains an invalid host identity')
    return name.lower()


def fresh(time, as_of):
    return timedelta(0) <= as_of - time <= FRESHNESS


def normalize_rows(rows, as_of):
    if not isinstance(rows, list) or not rows:
        raise RetentionError('fleet must be a nonempty row array')
    hosts = {}
    for row in rows:
        if not isinstance(row, dict) or not ROW_FIELDS <= row.keys():
            raise RetentionError('fleet row is missing required status fields')
        name = canonical_name(row['fqdn'])
        if name in hosts:
            raise RetentionError('fleet contains a duplicate host identity')
        if row['type'] not in ('node', 'storage') or row['hypervisor_type'] != 'vpsadminos':
            raise RetentionError('fleet contains an unsupported role or hypervisor')
        if row['status'] is not True:
            raise RetentionError('fleet contains a row without current status')
        reported = instant(row['last_report'])
        if not fresh(reported, as_of):
            raise RetentionError('fleet contains a stale or future status report')
        if not matches(RELEASE, row['kernel']):
            raise RetentionError('fleet contains an unsupported kernel release')
        hosts[name] = {field: row[field] for field in ROW_FIELDS}
        hosts[name].update(fqdn=name, last_report=utc_text(reported))
    return [hosts[name] for name in sorted(hosts)]


def project_response(response, acquired_at):
    # PublicStatus is a non-paginated HaveAPI action, not the /nodes index.
    if (not isinstance(response, dict)
            or response.keys() - {'version', 'status', 'response', 'message', 'errors'}
            or response.get('status') is not True):
        raise RetentionError('unexpected HaveAPI public-status envelope')
    output = response.get('response')
    if not isinstance(output, dict) or output.keys() != {'nodes'}:
        raise RetentionError('expected the unpaginated HaveAPI nodes response')
    return {'acquired_at': utc_text(acquired_at), 'nodes': normalize_rows(output['nodes'], acquired_at)}


def fetch_public_status():
    # Disable curl configuration/proxies; no redirects, requests to alternate
    # endpoints, credentials, cached fallback, or body/header logging.
    try:
        result = subprocess.run([
            'curl', '--disable', '--silent', '--noproxy', '*', '--proto', '=https',
            '--connect-timeout', '5', '--max-time', '15', '--max-filesize', str(MAX_BYTES),
            '--header', 'Accept: application/json', '--header', 'Cache-Control: no-cache',
            '--write-out', '\n%{http_code}\n%header{link}\n%header{content-range}', PUBLIC_STATUS,
        ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=17)
    except (OSError, subprocess.TimeoutExpired):
        raise RetentionError('public-status request failed') from None
    parts = result.stdout.rsplit(b'\n', 3)
    if result.returncode or len(parts) != 4 or parts[1:] != [b'200', b'', b'']:
        raise RetentionError('public-status request failed or returned an unexpected HTTP response')
    return json_input(parts[0])


def catalog_policy(catalog, as_of):
    # This policy reads only selectors and dates. The kernel-entry checker
    # validates the complete catalog schema before a candidate can be published.
    if not isinstance(catalog, dict) or catalog.keys() != CATALOG_FIELDS:
        raise RetentionError('invalid evaluated kernel catalog shape')
    entries = catalog['kernels']
    if not isinstance(entries, dict) or not entries:
        raise RetentionError('kernel catalog must be nonempty')
    selectors = [catalog['stableKernelVersion'], catalog['unstableKernelVersion']]
    if any(not matches(CATALOG_KEY, key) or key not in entries for key in selectors):
        raise RetentionError('kernel selector does not resolve to a catalog entry')
    retain_through = {}
    for key, entry in entries.items():
        if not matches(CATALOG_KEY, key) or not isinstance(entry, dict):
            raise RetentionError('invalid catalog kernel entry: expected an X.Y.Z key and an object')
        added = day(entry.get('dateAdded'))
        hold = day(entry['keepUntil']) if 'keepUntil' in entry else added
        if added > as_of.date() or hold < added:
            raise RetentionError(f'{key}: future introduction or hold before introduction')
        try:
            retain_through[key] = max(added + MINIMUM_AGE, hold)
        except OverflowError:
            raise RetentionError('kernel retention date is out of range') from None
    return selectors, retain_through


def plan(base, as_of, catalog, fleet, expected_digest):
    if not matches(r'[0-9a-f]{40}', base):
        raise RetentionError('base must be a full Git commit SHA')
    if not matches(r'[0-9a-f]{64}', expected_digest):
        raise RetentionError('an independently reconciled fleet SHA-256 digest is required')
    selectors, retain_through = catalog_policy(catalog, as_of)
    if not isinstance(fleet, dict) or fleet.keys() != {'acquired_at', 'nodes'}:
        raise RetentionError('invalid fleet projection')
    acquired = instant(fleet['acquired_at'], utc=True)
    if not fresh(acquired, as_of):
        raise RetentionError('fleet acquisition is stale or in the future')
    rows = normalize_rows(fleet['nodes'], acquired)
    # Canonical DNS names are ASCII, hence Python lexical order is byte order.
    digest = hashlib.sha256(''.join(row['fqdn'] + '\n' for row in rows).encode('utf-8')).hexdigest()
    if digest != expected_digest:
        raise RetentionError('fleet membership does not match the trusted roster')

    in_use = set()
    for row in rows:
        if not fresh(instant(row['last_report']), as_of):
            raise RetentionError('fleet report is stale at plan time')
        # A canonical numbered livepatch report protects its exact base key.
        # Never strip unrecognized suffixes or match a version prefix.
        key = RELEASE.fullmatch(row['kernel'])[1]
        if key not in retain_through:
            raise RetentionError('fleet contains a kernel release absent from the catalog')
        in_use.add(key)

    decisions = {}
    for key, through in sorted(retain_through.items()):
        reasons = []
        if key == selectors[0]:
            reasons.append('stable-selector')
        if key == selectors[1]:
            reasons.append('unstable-selector')
        if as_of.date() <= through:
            reasons.append('retention-date')
        if key in in_use:
            reasons.append('in-use')
        decisions[key] = {'retain_through': through.isoformat(), 'reasons': reasons}
    return {
        'base': base, 'as_of': utc_text(as_of), 'fleet_count': len(rows), 'decisions': decisions,
        'eligible': [key for key, decision in decisions.items() if not decision['reasons']],
    }


def transaction(args):
    import kernel_retention_transaction as txn

    try:
        if args.command == 'apply':
            txn.clean_checkout(args.base)
            txn.guard_tree(txn.tree(args.base))
            observed = txn.snapshot(args.base)
            report = plan(args.base, instant(args.as_of, utc=True), observed['catalog'],
                          read_json(args.fleet), args.expected_fleet_sha256)
            delete, _, nav_changed = txn.changes(args.base, observed, report['eligible'])
            paths = sorted(delete + ([txn.NAV] if nav_changed else []))
            if args.write and paths:
                observed = txn.snapshot(args.base, full=True)
            evidence = {'report': report, 'base': observed, 'fleet_sha256': args.expected_fleet_sha256}
            with args.evidence.open('x', encoding='utf-8') as stream:
                stream.write(json.dumps(evidence, sort_keys=True) + '\n')
            if args.write and paths:
                if txn.apply(args.base, observed, report['eligible']) != paths:
                    raise txn.TransactionError('applied paths differ from the planned retirement')
            print(json.dumps({**report, 'changed_paths': sorted(paths)}, sort_keys=True))
        else:
            evidence = read_json(args.evidence)
            base = txn.sha(args.base)
            if evidence['report']['base'] != base:
                raise txn.TransactionError('transaction evidence does not match the expected base')
            eligible = evidence['report']['eligible']
            candidate = txn.sha(args.candidate)
            expected = txn.verify_tree(base, candidate, evidence['base'], eligible)
            proof = txn.binding(candidate, expected, evidence)
            if args.command == 'verify':
                txn.clean_checkout(candidate)
                txn.guard_tree(txn.tree(candidate))
                txn.verify_evidence(evidence['base'], txn.snapshot(candidate, full=True), eligible,
                                    txn.removed_batch_checks(base, eligible))
                stamp = instant(evidence['report']['as_of'], utc=True).date().isoformat()
                subprocess.run([
                    sys.executable, 'tools/kernel-entry-check.py', 'check', '--as-of', stamp,
                    '--base', base, '--tree', candidate,
                ], check=True)
                print(json.dumps(proof, sort_keys=True))
            else:
                if proof != read_json(args.proof):
                    raise txn.TransactionError('candidate does not match the offline verification proof')
                if args.command == 'recheck':
                    now = instant(args.as_of, utc=True)
                    fleet = read_json(args.fleet)
                    previous = instant(evidence['report']['as_of'], utc=True)
                    acquired = instant(fleet.get('acquired_at') if isinstance(fleet, dict) else None, utc=True)
                    if acquired <= previous:
                        raise RetentionError('second collection is not newer than the initial plan')
                    report = plan(base, now, evidence['base']['catalog'], fleet, args.expected_fleet_sha256)
                    if (args.expected_fleet_sha256 != evidence['fleet_sha256'] or report['eligible'] != eligible
                            or report['fleet_count'] != evidence['report']['fleet_count']):
                        raise RetentionError('fresh eligibility or coverage differs from the tested transaction')
                    # The writer must start and finish its bounded push before
                    # the oldest evidence expires, not just within 120 seconds
                    # of its second HTTP request.
                    oldest = min(acquired, *(instant(row['last_report']) for row in fleet['nodes']))
                    deadline = oldest + FRESHNESS
                    print(json.dumps({**report, 'fresh_until_ms': int(deadline.timestamp() * 1000)},
                                     sort_keys=True))
        return 0
    except txn.TransactionError as error:
        raise RetentionError(str(error)) from None
    except (KeyError, TypeError, subprocess.CalledProcessError):
        raise RetentionError('invalid transaction inputs or failed Git/Nix verification') from None


def plan_args(command):
    command.add_argument('--as-of', required=True, help='explicit UTC timestamp')
    command.add_argument('--fleet', type=Path, required=True, help='private collected projection')
    command.add_argument('--expected-fleet-sha256', required=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    collect = commands.add_parser('collect', help='write a private fleet projection (read-only GET)')
    collect.add_argument('--output', type=Path, required=True, help='new private file, not a log or artifact')
    collect.add_argument('--fixture', type=Path, help='read a HaveAPI JSON fixture instead of HTTPS')
    collect.add_argument('--acquired-at', help='explicit UTC acquisition timestamp for --fixture only')
    planning = commands.add_parser('plan', help='report eligible versions; no network or system clock')
    planning.add_argument('--base', required=True, help='SHA from which the caller evaluated the catalog')
    planning.add_argument('--catalog', type=Path, required=True, help='evaluated lib.availableKernels JSON')
    plan_args(planning)
    application = commands.add_parser('apply', help='plan or commit retirements in a disposable checkout')
    application.add_argument('--base', required=True)
    application.add_argument('--evidence', type=Path, required=True, help='write transaction evidence outside Git')
    application.add_argument('--write', action='store_true',
                             help='advance a clean detached checkout by one hooked commit per retired kernel')
    plan_args(application)
    for command, help_text in (
        ('verify', 'verify every retirement commit and evaluate the tip offline'),
        ('verify-tree', 'check each retirement commit against existing offline proof'),
        ('recheck', 'verify the proof and compare newly collected eligibility on the base'),
    ):
        check = commands.add_parser(command, help=help_text)
        check.add_argument('--base', required=True)
        check.add_argument('--candidate', required=True)
        check.add_argument('--evidence', type=Path, required=True)
        if command != 'verify':
            check.add_argument('--proof', type=Path, required=True)
        if command == 'recheck':
            plan_args(check)
    args = parser.parse_args(argv)

    try:
        if args.command == 'collect':
            if (args.fixture is None) != (args.acquired_at is None):
                raise RetentionError('--fixture and --acquired-at must be supplied together')
            if args.fixture is None:
                response = fetch_public_status()
                acquired = datetime.now(timezone.utc)
            else:
                response = read_json(args.fixture)
                acquired = instant(args.acquired_at, utc=True)
            projection = project_response(response, acquired)
            with os.fdopen(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600),
                           'w', encoding='utf-8') as stream:
                json.dump(projection, stream, sort_keys=True)
                stream.write('\n')
        elif args.command == 'plan':
            report = plan(args.base, instant(args.as_of, utc=True), read_json(args.catalog),
                          read_json(args.fleet), args.expected_fleet_sha256)
            print(json.dumps(report, sort_keys=True))
        else:
            return transaction(args)
        return 0
    except RetentionError as error:
        print(f'kernel-retention: {error}', file=sys.stderr)
    except OSError:
        print('kernel-retention: failed to read or write an input or output file', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
