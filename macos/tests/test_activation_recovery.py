import importlib.util
from pathlib import Path
import tempfile
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
