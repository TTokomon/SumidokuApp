"""Service lifecycle contracts using a disposable launchctl simulation, never the real job."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).parents[1] / 'service.sh'


class ServiceTests(unittest.TestCase):
    def run_helper(self, action, loaded=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = root / 'state.json'
            events = root / 'events'
            state.write_text(json.dumps({'loaded': loaded, 'pid': 99999999}))
            stub = root / 'launchctl'
            stub.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
from pathlib import Path
state_file = Path(os.environ['TEST_STATE'])
state = json.loads(state_file.read_text())
args = sys.argv[1:]
with open(os.environ['TEST_EVENTS'], 'a') as log: log.write(' '.join(args) + '\\n')
if args[0] == 'print':
    if not state['loaded']: sys.exit(1)
    print('pid =', state['pid'])
elif args[0] == 'kill':
    assert args[1] == 'SIGTERM'
    state['pid'] -= 1
elif args[0] == 'bootout': state['loaded'] = False
elif args[0] == 'bootstrap': state['loaded'] = True
else: sys.exit(2)
state_file.write_text(json.dumps(state))
''')
            stub.chmod(0o700)
            curl = root / 'curl'
            curl.write_text('#!/bin/sh\nexit 0\n')
            curl.chmod(0o700)
            opener = root / 'open'
            opener.write_text(f'#!{sys.executable}\n' + 'import os, sys\nfrom pathlib import Path\nPath(os.environ["TEST_EVENTS"]).write_text("open " + " ".join(sys.argv[1:]) + "\\n")\n')
            opener.chmod(0o700)
            environment = {**os.environ, 'HOME': str(root), 'PATH': str(root) + ':' + os.environ['PATH'],
                           'TEST_STATE': str(state), 'TEST_EVENTS': str(events)}
            result = subprocess.run(['/bin/bash', str(HELPER), action], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return events.read_text().splitlines()

    def test_open_launches_native_app_without_browser_or_server_control(self):
        self.assertEqual(self.run_helper('open'), ['open /Applications/Sumidoku.app'])

    def test_restart_signals_existing_job_without_unregistering_it(self):
        events = self.run_helper('restart')
        self.assertTrue(any(item.startswith('kill SIGTERM ') for item in events), events)
        self.assertFalse(any(item.startswith(('bootout ', 'bootstrap ')) for item in events), events)

    def test_start_running_job_does_not_create_duplicate(self):
        events = self.run_helper('start')
        self.assertTrue(all(item.startswith('print ') for item in events), events)

    def test_start_unloaded_job_bootstraps_once(self):
        events = self.run_helper('start', loaded=False)
        self.assertEqual(sum(item.startswith('bootstrap ') for item in events), 1)


if __name__ == '__main__':
    unittest.main()
