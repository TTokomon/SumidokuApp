"""Exercise the shipped path and notice bytes in actual ZIP files."""

import hashlib
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "macos/Distribution"))
import release_notices
PREFIX = "Sumidoku.app/Contents/Resources/"
MIT = "Sumidoku-LICENSE.txt"
SPARKLE = "Sparkle-LICENSE.txt"


class ReleaseNoticeTests(unittest.TestCase):
    def test_archive_requires_original_notices(self):
        original = (ROOT / "LICENSE").read_bytes()
        sparkle = b"fixture Sparkle notice"
        hashes = dict(release_notices.NOTICES, **{SPARKLE: hashlib.sha256(sparkle).hexdigest()})
        cases = [
            (original, stat.S_IFREG, True, None),
            (None, stat.S_IFREG, True, "Missing or duplicate.*Sumidoku"),
            (original.splitlines()[0], stat.S_IFREG, True, "match the original.*Sumidoku"),
            (original, stat.S_IFLNK, True, "Invalid.*Sumidoku"),
            (original, stat.S_IFREG, False, "Missing or duplicate.*Sparkle"),
        ]
        for notice, mode, has_sparkle, error in cases:
            with self.subTest(mode=mode, error=error), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "release.zip"
                with zipfile.ZipFile(path, "w") as package:
                    if notice is not None:
                        item = zipfile.ZipInfo(PREFIX + MIT)
                        item.create_system = 3
                        item.external_attr = (mode | 0o644) << 16
                        package.writestr(item, notice)
                    if has_sparkle:
                        item = zipfile.ZipInfo(PREFIX + SPARKLE)
                        item.create_system = 3
                        item.external_attr = (stat.S_IFREG | 0o644) << 16
                        package.writestr(item, sparkle)
                with patch.object(release_notices, "NOTICES", hashes):
                    if error:
                        with self.assertRaisesRegex(ValueError, error):
                            release_notices.verify_notices(path)
                    else:
                        release_notices.verify_notices(path)
