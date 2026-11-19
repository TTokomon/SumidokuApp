import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnose_lookup


class LookupDiagnosticTests(unittest.TestCase):
    def test_status_is_independent_of_cli_wording_and_sensitive_output(self):
        for status in (401, 403, 404, 429, 500):
            for stderr in ('arbitrary secret details', f'gh: error (HTTP {status})'):
                with self.subTest(status=status, stderr=stderr):
                    response = subprocess.CompletedProcess(
                        [], 1, f'HTTP/2 {status}\nAuthorization: fixture-secret\n\n{{}}', stderr,
                    )
                    with patch.object(diagnose_lookup.subprocess, 'run', return_value=response) as run:
                        with contextlib.redirect_stdout(io.StringIO()) as log:
                            self.assertEqual(diagnose_lookup.probe('Release lookup', 'test'), (status, None))
                        self.assertIn(f'HTTP {status}', log.getvalue())
                        self.assertNotIn('secret', log.getvalue())
                        self.assertEqual(run.call_args.args[0], ['gh', 'api', '--method', 'GET', '--include', 'test'])

    def test_no_response_is_a_transport_error(self):
        for result in (subprocess.CompletedProcess([], 1, '', 'fixture secret'), FileNotFoundError(), subprocess.TimeoutExpired([], 30)):
            kwargs = {'side_effect': result} if isinstance(result, Exception) else {'return_value': result}
            with self.subTest(result=type(result)), patch.object(diagnose_lookup.subprocess, 'run', **kwargs):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(diagnose_lookup.probe('Release', 'test'), (None, None))
                self.assertEqual(output.getvalue(), 'Release: no HTTP response\n')

    def test_valid_json_body(self):
        raw = 'HTTP/1.1 200 OK\r\nServer: GitHub\r\n\r\n' + json.dumps({'draft': True})
        with patch.object(diagnose_lookup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, raw, '')):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(diagnose_lookup.probe('Release', 'test'), (200, {'draft': True}))

    def test_missing_or_malformed_credential_never_requests_api(self):
        for token in ('', 'test token'):
            with patch.dict(os.environ, {'GH_TOKEN': token}), patch.object(diagnose_lookup, 'probe') as probe:
                with self.assertRaises(SystemExit):
                    diagnose_lookup.diagnose('1.3.1-beta.1', '450282463')
                probe.assert_not_called()

    def test_only_404_uses_listing(self):
        version = '1.3.1-beta.1'
        draft = {
            'id': 450282463, 'tag_name': 'desktop-v'+version, 'draft': True, 'prerelease': True,
            'target_commitish': diagnose_lookup.common.selected(version)['sourceRevision'],
        }
        for status in (401, 403, 404, 429, None):
            responses = [(200, {}), (200, {}), (status, None), (200, draft), (200, [draft])]
            with self.subTest(status=status), patch.dict(os.environ, {'GH_TOKEN': 'fixture-only'}):
                with patch.object(diagnose_lookup, 'probe', side_effect=responses) as probe, contextlib.redirect_stdout(io.StringIO()):
                    if status == 404:
                        diagnose_lookup.diagnose(version, str(draft['id']))
                        self.assertEqual(probe.call_count, 5)
                    else:
                        with self.assertRaises(SystemExit):
                            diagnose_lookup.diagnose(version, str(draft['id']))
                        self.assertEqual(probe.call_count, 4)
