"""Verify the original Sumidoku and Sparkle notices in a desktop release ZIP."""

import hashlib
from pathlib import Path
import stat
import sys
import zipfile

# Hashes of the reviewed repository LICENSE and bundled Sparkle license.
NOTICES = {
    "Sumidoku-LICENSE.txt": "b2c754b5a20163153451942c1d9629c3e2e1f4ac1f548ab0eaf2243a4a8ae011",
    "Sparkle-LICENSE.txt": "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe",
}


def verify_notices(archive: Path) -> None:
    with zipfile.ZipFile(archive) as package:
        for name, expected in NOTICES.items():
            path = f"Sumidoku.app/Contents/Resources/{name}"
            entries = [item for item in package.infolist() if item.filename == path]
            if len(entries) != 1:
                raise ValueError(f"Missing or duplicate release notice: {name}")
            entry = entries[0]
            mode = entry.external_attr >> 16
            if not stat.S_ISREG(mode) or not 0 < entry.file_size <= 128 * 1024:
                raise ValueError(f"Invalid release notice file: {name}")
            if hashlib.sha256(package.read(entry)).hexdigest() != expected:
                raise ValueError(f"Release notice does not match the original: {name}")


if __name__ == "__main__":
    verify_notices(Path(sys.argv[1]))
