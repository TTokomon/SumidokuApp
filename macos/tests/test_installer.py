"""Binary caching must never silently create an owner or a managed service."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_installer', Path(__file__).parents[1] / 'install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_binary_cache_creates_no_account_configuration_database_or_agent(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            archive = io.BytesIO()
            payload = b'disposable executable fixture'
            with tarfile.open(fileobj=archive, mode='w:gz') as tar:
                entry = tarfile.TarInfo(f'sumidoku_{installer.VERSION}_aarch64-apple-darwin/sumidoku-server')
                entry.size = len(payload)
                tar.addfile(entry, io.BytesIO(payload))
            content = archive.getvalue()
            with patch.object(installer.Path, 'home', return_value=home), \
                    patch.object(installer.platform, 'system', return_value='Darwin'), \
                    patch.object(installer.platform, 'machine', return_value='arm64'), \
                    patch.object(installer, 'SHA256', hashlib.sha256(content).hexdigest()), \
                    patch.object(installer.urllib.request, 'urlopen', return_value=io.BytesIO(content)), \
                    contextlib.redirect_stdout(io.StringIO()):
                installer.main()
                installer.main()  # Existing binary must be reused without another download.
            actual = [p.relative_to(home).as_posix() for p in home.rglob('*') if p.is_file()]
            self.assertEqual(actual, ['Library/Application Support/Sumidoku/bin/sumidoku-server'])
