import importlib.util
from pathlib import Path
import tempfile
import re
import unittest

spec = importlib.util.spec_from_file_location('activation', Path(__file__).resolve().parents[1] / 'activate-fork.py')
activation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activation)


class ActivationRecoveryTests(unittest.TestCase):
    def test_restore_matching_runtime_before_previous_service_restarts(self):
        with tempfile.TemporaryDirectory(prefix='sumidoku-activation-fixture-') as directory:
            root = Path(directory)
            recovery = root / 'Recovery'
            recovery.mkdir()
            runtime = root / 'Runtime'
            (runtime / 'bin').mkdir(parents=True)
            fork = runtime / 'bin/sumidoku-server-fork'
            runner = runtime / 'bin/run-server.sh'
            agent = root / 'agent.plist'
            artifacts = {
                'previous-fork': fork,
                'run-server.sh': runner,
                'LaunchAgent.plist': agent,
                'server-build.json': runtime / 'server-build.json',
            }
            for name, target in artifacts.items():
                (recovery / name).write_text('previous-' + name)
                target.write_text('new-' + name)
            activation.restore_previous_runtime(recovery, fork, runner, agent)
            for name, target in artifacts.items():
                self.assertEqual(target.read_text(), 'previous-' + name)
            self.assertEqual(fork.stat().st_mode & 0o777, 0o700)
            self.assertEqual(runner.stat().st_mode & 0o777, 0o700)

    def test_executable_replacement_uses_a_new_inode(self):
        with tempfile.TemporaryDirectory(prefix='sumidoku-inode-fixture-') as directory:
            root = Path(directory)
            source, target = root / 'new-server', root / 'installed-server'
            source.write_bytes(b'new-executable')
            target.write_bytes(b'previous-executable')
            old_inode = target.stat().st_ino
            activation.atomic_copy(source, target)
            self.assertNotEqual(target.stat().st_ino, old_inode)
            self.assertEqual(target.read_bytes(), b'new-executable')
            self.assertEqual(target.stat().st_mode & 0o777, 0o700)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['installed-server', 'new-server'])

    def test_running_client_detection_includes_diagnostic_arguments(self):
        binary = '/Applications/Sumidoku.app/Contents/MacOS/Sumidoku'
        self.assertRegex(binary, activation.APPLICATION_PROCESS_PATTERN)
        self.assertRegex(binary + ' --capture-window /tmp/own-window.png', activation.APPLICATION_PROCESS_PATTERN)
        self.assertIsNone(re.search(activation.APPLICATION_PROCESS_PATTERN, binary + 'Helper'))
        self.assertIsNone(re.search(activation.APPLICATION_PROCESS_PATTERN, '/tmp' + binary))
