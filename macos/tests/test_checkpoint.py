import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('checkpoint', Path(__file__).parents[1] / 'checkpoint.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CheckpointTests(unittest.TestCase):
    def test_empty_corrupt_or_unsupported_backup_cannot_replace_good_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'export.json'
            good = {'version': 1, 'library': [{'inLibrary': True, 'key': 'synthetic'}],
                    'categories': [], 'progress': []}
            source.write_text(json.dumps(good))
            original = source.read_bytes()
            first = module.checkpoint(source, root / 'checkpoints')
            second = module.checkpoint(source, root / 'checkpoints')
            self.assertNotEqual(first, second)
            for bad in ['broken JSON', json.dumps({**good, 'library': []}), json.dumps({**good, 'version': 999})]:
                source.write_text(bad)
                with self.assertRaises(ValueError):
                    module.checkpoint(source, root / 'checkpoints')
                self.assertEqual(first.read_bytes(), original)
            self.assertEqual(len(list((root / 'checkpoints').glob('*.json'))), 2)


if __name__ == '__main__':
    unittest.main()
