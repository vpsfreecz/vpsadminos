import copy
import json
import os
import runpy
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'kernel-retention.py'
FIXTURES = Path(__file__).with_name('fixtures')
TOOL = runpy.run_path(str(SCRIPT))
BASE = 'b86287c105b749827cd63632ac35936533910f63'
AS_OF = '2026-12-02T12:00:00Z'


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.api = TOOL['read_json'](FIXTURES / 'public_status.json')
        self.catalog = TOOL['read_json'](FIXTURES / 'catalog.json')
        self.as_of = TOOL['instant'](AS_OF, utc=True)

    def plan(self, timestamp=None, *, fleet=None):
        now = TOOL['instant'](timestamp, utc=True) if timestamp else self.as_of
        if fleet is None:
            for row in self.api['response']['nodes']:
                row['last_report'] = TOOL['utc_text'](now)
            fleet = TOOL['project_response'](self.api, now)
        return TOOL['plan'](BASE, now, self.catalog, fleet)

    def test_reasons_and_inclusive_dates(self):
        result = self.plan()
        self.assertEqual(result['eligible'], ['6.12.11'])
        self.assertEqual(result['decisions']['6.12.110']['reasons'], ['in-use'])
        self.assertEqual(result['decisions']['6.12.118']['reasons'], ['stable-selector', 'in-use'])
        self.assertEqual(result['decisions']['6.18.49']['reasons'], ['unstable-selector'])
        self.assertEqual(result['decisions']['6.12.109']['retain_through'], '2026-12-02')
        self.assertEqual(self.plan('2026-12-01T23:59:59Z')['eligible'], [])
        self.assertEqual(self.plan('2027-01-31T23:59:59Z')['eligible'], ['6.12.109', '6.12.11'])
        self.assertEqual(self.plan('2027-02-01T00:00:00Z')['eligible'], ['6.12.109', '6.12.11', '6.12.113'])

    def test_leap_day_and_shared_selector(self):
        self.catalog['kernels']['6.12.11']['dateAdded'] = '2028-02-29'
        self.catalog['unstableKernelVersion'] = '6.12.118'
        self.assertNotIn('6.12.11', self.plan('2028-03-30T12:00:00Z')['eligible'])
        result = self.plan('2028-03-31T12:00:00Z')
        self.assertIn('6.12.11', result['eligible'])
        self.assertEqual(result['decisions']['6.12.118']['reasons'],
                         ['stable-selector', 'unstable-selector', 'in-use'])

    def test_numbered_fleet_release_protects_only_its_base_key(self):
        result = self.plan()
        self.assertEqual(result['decisions']['6.12.110']['reasons'], ['in-use'])
        self.assertIn('6.12.11', result['eligible'])

    def test_numbered_catalog_key_and_selector_are_rejected(self):
        self.catalog['kernels']['6.12.110.3'] = {'dateAdded': '2026-08-01'}
        with self.assertRaisesRegex(TOOL['RetentionError'], r'expected an X\.Y\.Z key'):
            self.plan()
        self.catalog['stableKernelVersion'] = '6.12.110.3'
        with self.assertRaisesRegex(TOOL['RetentionError'], 'kernel selector'):
            self.plan()

    def test_packaging_fields_do_not_change_policy(self):
        original = self.plan()
        self.catalog['kernels']['6.12.11']['futurePackageOptions'] = {'variant': ['example']}
        self.assertEqual(self.plan(), original)

    def test_projection_is_minimal_and_sorted(self):
        fleet = TOOL['project_response'](self.api, self.as_of)
        del self.api['response']['_meta']
        self.assertEqual(fleet, TOOL['project_response'](self.api, self.as_of))
        names = [row['fqdn'] for row in fleet['nodes']]
        self.assertEqual(names, ['node.example.invalid', 'storage.example.invalid'])
        self.assertEqual(fleet['nodes'][1]['last_report'], '2026-12-02T11:59:30Z')
        self.assertEqual(fleet['nodes'][1].keys(), TOOL['ROW_FIELDS'])
        self.assertEqual(self.plan(fleet=fleet)['fleet_count'], 2)

    def test_reordered_inputs_produce_same_plan(self):
        result = self.plan()
        self.api['response']['nodes'].reverse()
        self.catalog['kernels'] = dict(reversed(list(self.catalog['kernels'].items())))
        self.assertEqual(self.plan(), result)
        self.assertEqual(list(result['decisions']), sorted(result['decisions']))

    def test_invalid_entries(self):
        for entry in ({}, {'dateAdded': None}, {'dateAdded': '2026-2-05'},
                      {'dateAdded': '2026-02-29'}, {'dateAdded': '2026-12-03'},
                      {'dateAdded': '2026-11-01', 'keepUntil': None},
                      {'dateAdded': '2026-11-01', 'keepUntil': '2026-10-31'},
                      {'dateAdded': '2026-11-01', 'keepUntil': '2027-02-29'}):
            with self.subTest(entry=entry), self.assertRaises(TOOL['RetentionError']):
                self.catalog['kernels']['6.12.11'] = entry
                self.plan()
        self.catalog['stableKernelVersion'] = '6.12.112'
        with self.assertRaises(TOOL['RetentionError']):
            self.plan()

    def test_reject_invalid_envelope_or_coverage(self):
        original = copy.deepcopy(self.api)
        for mutation in (
            lambda api: api.update(status=False),
            lambda api: api.update(status=1),
            lambda api: api.update(next='next'),
            lambda api: api['response'].update(pagination={}),
            lambda api: api['response'].update(nodes=[]),
            lambda api: api['response']['nodes'][1].update(fqdn='STORAGE.example.invalid.'),
            lambda api: api['response']['nodes'][1].update(fqdn='invalid..example'),
            lambda api: api['response']['nodes'][1].update(type='mailer'),
            lambda api: api['response']['nodes'][1].update(hypervisor_type='openvz'),
            lambda api: api['response']['nodes'][1].update(status=False),
            lambda api: api['response']['nodes'][1].pop('status'),
            lambda api: api['response']['nodes'][1].update(status=1),
            lambda api: api['response']['nodes'][1].update(kernel='6.12.118-custom'),
            lambda api: api['response']['nodes'][1].update(kernel='6.12.118.0'),
            lambda api: api['response']['nodes'][1].update(last_report='2026-12-02T11:59:59'),
            lambda api: api['response']['nodes'][1].update(last_report='2026-12-02T12:00:01Z'),
            lambda api: api['response']['nodes'][1].update(last_report='2026-12-02T11:57:59Z'),
        ):
            api = copy.deepcopy(original)
            mutation(api)
            with self.assertRaises(TOOL['RetentionError']):
                TOOL['project_response'](api, self.as_of)

    def test_reject_nonempty_or_malformed_status_metadata(self):
        for meta in ({'next': 'another-page'}, {'total': 2}, None, False, [], ''):
            with self.subTest(meta=meta), self.assertRaisesRegex(TOOL['RetentionError'], 'unpaginated'):
                self.api['response']['_meta'] = meta
                TOOL['project_response'](self.api, self.as_of)

    def test_unknown_release_fails(self):
        self.api['response']['nodes'][0]['kernel'] = '6.12.1'
        with self.assertRaisesRegex(TOOL['RetentionError'], 'absent'):
            self.plan()

    def test_api_membership_can_change_between_runs(self):
        first = self.plan()
        nodes = self.api['response']['nodes']
        nodes.pop(0)
        nodes[0]['fqdn'] = 'replacement.example.invalid'
        second = self.plan('2026-12-09T12:00:00Z')
        self.assertEqual((first['fleet_count'], second['fleet_count']), (2, 1))
        self.assertIn('in-use', first['decisions']['6.12.110']['reasons'])
        self.assertIn('6.12.110', second['eligible'])

    def test_projection_not_implicitly_trusted_and_expires(self):
        self.api['response']['nodes'][1]['last_report'] = '2026-12-02T11:58:00Z'
        fleet = TOOL['project_response'](self.api, self.as_of)
        self.plan(fleet=fleet)
        with self.assertRaisesRegex(TOOL['RetentionError'], 'stale at plan time'):
            self.plan('2026-12-02T12:00:01Z', fleet=fleet)
        with self.assertRaisesRegex(TOOL['RetentionError'], 'acquisition'):
            self.plan('2026-12-02T12:02:01Z', fleet=fleet)
        with self.assertRaisesRegex(TOOL['RetentionError'], 'acquisition'):
            self.plan('2026-12-02T11:59:59Z', fleet=fleet)
        fleet['nodes'][1]['fqdn'] = fleet['nodes'][0]['fqdn'].upper() + '.'
        with self.assertRaisesRegex(TOOL['RetentionError'], 'duplicate'):
            self.plan(fleet=fleet)
        fresh_rows = TOOL['project_response'](self.api, self.as_of)['nodes']
        for row in fresh_rows:
            row['last_report'] = AS_OF
        fleet['nodes'] = fresh_rows
        # Both acquisition and reports can be exactly 120 seconds old.
        self.plan(TOOL['utc_text'](self.as_of + timedelta(seconds=120)), fleet=fleet)

    def test_strict_json(self):
        for raw in (b'{"status":false,"status":true}', b'{"status":NaN}', b'\xff',
                    b'x' * (TOOL['MAX_BYTES'] + 1)):
            with self.subTest(size=len(raw)), self.assertRaises(TOOL['RetentionError']):
                TOOL['json_input'](raw)

    def test_http_status_content_and_transport_failures(self):
        body = (FIXTURES / 'public_status.json').read_bytes()
        with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, body + b'\n200\n\n')) as run:
            self.assertEqual(TOOL['fetch_public_status'](), self.api)
            command = run.call_args.args[0]
            self.assertEqual(command[:2], ['curl', '--disable'])
            self.assertEqual(command[-1], TOOL['PUBLIC_STATUS'])
            self.assertNotIn('--location', command)
            self.assertIn('--max-time', command)
            self.assertIs(run.call_args.kwargs['stderr'], subprocess.DEVNULL)
        for status, link, content_range in (
            (b'401', b'', b''), (b'503', b'', b''), (b'301', b'', b''), (b'206', b'', b''),
            (b'200', b'next', b''), (b'200', b'', b'1-2/3'),
        ):
            reply = b'\n'.join((body, status, link, content_range))
            with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, reply)):
                with self.assertRaises(TOOL['RetentionError']):
                    TOOL['fetch_public_status']()
        for error in (OSError('not a public diagnostic'), subprocess.TimeoutExpired('curl', 17)):
            with patch.object(subprocess, 'run', side_effect=error):
                with self.assertRaisesRegex(TOOL['RetentionError'], '^public-status request failed$'):
                    TOOL['fetch_public_status']()

    def test_cli_does_not_leak_projection_or_overwrite_it(self):
        def run(*args):
            return subprocess.run([sys.executable, '-B', SCRIPT, *args], capture_output=True, text=True)

        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'private.json'
            collect = ('collect', '--fixture', FIXTURES / 'public_status.json',
                       '--acquired-at', AS_OF, '--output', output)
            result = run(*collect)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))
            self.assertEqual(stat.S_IMODE(os.stat(output).st_mode), 0o600)
            data = output.read_bytes()
            result = run(*collect)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(output.read_bytes(), data)
            planning = ('plan', '--base', BASE, '--as-of', AS_OF, '--fleet', output,
                        '--catalog', FIXTURES / 'catalog.json')
            result = run(*planning)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)['eligible'], ['6.12.11'])
            self.assertNotIn('example.invalid', result.stdout + result.stderr)
            fleet = json.loads(data)
            fleet['nodes'][0]['fqdn'] = fleet['nodes'][1]['fqdn']
            output.write_text(json.dumps(fleet))
            result = run(*planning)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, '')
            self.assertNotIn('example.invalid', result.stderr)


if __name__ == '__main__':
    unittest.main()
