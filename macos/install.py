#!/usr/bin/env python3
"""Cache only the pinned server binary for building the native client."""
import hashlib
import io
import os
from pathlib import Path
import platform
import shutil
import tarfile
import urllib.request

VERSION = '1.23.3'
SHA256 = 'c6fcd267ab03cc456199fbc556ed1b7b8b49c41f8c0858f63e90b7eeb05318a1'
URL = f'https://github.com/Sumidoku/Sumidoku/releases/download/v{VERSION}/sumidoku_{VERSION}_aarch64-apple-darwin.tar.gz'


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This installer requires native Apple Silicon macOS.')
    os.umask(0o077)
    binary = Path.home() / 'Library/Application Support/Sumidoku/bin/sumidoku-server'
    if binary.exists():
        print('Existing server binary preserved. Open Sumidoku.app to create or connect to a library.')
        return
    archive = urllib.request.urlopen(URL, timeout=120).read()
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise SystemExit('Official release SHA-256 mismatch; nothing installed.')
    binary.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        member = tar.getmember(f'sumidoku_{VERSION}_aarch64-apple-darwin/sumidoku-server')
        if not member.isfile():
            raise SystemExit('Expected a regular executable in the release archive.')
        with binary.open('xb') as target:
            shutil.copyfileobj(tar.extractfile(member), target)
    binary.chmod(0o700)
    print(f'Cached official Sumidoku {VERSION}; checksum verified.')
    print('No account, database, configuration or LaunchAgent was created. Continue in Sumidoku.app.')


if __name__ == '__main__':
    main()
