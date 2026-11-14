#!/usr/bin/env python3
"""Install the pinned official ARM64 release and a private user LaunchAgent."""
import hashlib
import io
import os
from pathlib import Path
import platform
import plistlib
import secrets
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
    home = Path.home()
    data = home / 'Library/Application Support/Sumidoku'
    logs = home / 'Library/Logs/Sumidoku'
    backups = home / 'Documents/Sumidoku Backups'
    downloads = data / 'downloads'
    existing = [data / 'bin/sumidoku-server', data / 'config.toml',
                home / 'Library/LaunchAgents/app.sumidoku.server.plist']
    if any(item.exists() for item in existing):
        raise SystemExit('An installation or configuration already exists; use the backup-first update procedure.')
    for directory in [data, logs, backups, downloads, data / 'bin', backups / 'checkpoints']:
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o700)
    # Refuse an uncoordinated replacement while a live service might be using the old binary.
    binary = data / 'bin/sumidoku-server'
    if binary.exists():
        raise SystemExit('Already installed. Use the documented backup-first update procedure.')
    archive = urllib.request.urlopen(URL, timeout=120).read()
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise SystemExit('Official release SHA-256 mismatch; nothing installed.')
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        member = tar.getmember(f'sumidoku_{VERSION}_aarch64-apple-darwin/sumidoku-server')
        if not member.isfile():
            raise SystemExit('Expected a regular executable in the release archive.')
        with binary.open('xb') as target:
            shutil.copyfileobj(tar.extractfile(member), target)
    binary.chmod(0o700)
    config = data / 'config.toml'
    if config.exists():
        raise SystemExit('Existing config preserved; review it before enabling the LaunchAgent.')
    # JSON strings are also valid basic TOML strings for these filesystem paths.
    import json
    config.write_text('\n'.join([
        'addr = "127.0.0.1:3000"',
        f'downloads_dir = {json.dumps(str(downloads))}',
        'auto_download_new_chapters = false', 'auto_download_limit = 0',
        'update_interval_hours = 0', 'local_scan_secs = 0',
        'local_scan_on_startup = false', 'backup_enabled = true',
        'backup_interval_hours = 24', 'backup_retention_count = 30',
        f'backup_dir = {json.dumps(str(backups))}',
        '', '[auth]', 'username = "admin"', f'password = "{secrets.token_urlsafe(24)}"', '',
    ]))
    config.chmod(0o600)
    runner = data / 'bin/run-server.sh'
    shutil.copyfile(Path(__file__).with_name('run-server.sh'), runner)
    runner.chmod(0o700)
    agent = home / 'Library/LaunchAgents/app.sumidoku.server.plist'
    agent.parent.mkdir(parents=True, exist_ok=True)
    if agent.exists():
        raise SystemExit('Existing LaunchAgent preserved; review it before proceeding.')
    plist = {
        'Label': 'app.sumidoku.server',
        'ProgramArguments': ['/bin/bash', str(runner)],
        'WorkingDirectory': str(data),
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
        'ExitTimeOut': 30, 'ProcessType': 'Background', 'Umask': 0o077,
        'StandardOutPath': str(logs / 'server.log'),
        'StandardErrorPath': str(logs / 'server-error.log'),
    }
    with agent.open('xb') as target:
        plistlib.dump(plist, target)
    agent.chmod(0o600)
    (data / 'installed-release.json').write_text(json.dumps({
        'version': VERSION, 'url': URL, 'sha256': SHA256,
    }, indent=2) + '\n')
    print(f'Installed official Sumidoku {VERSION}; checksum verified.')
    print('Private configuration and login password saved outside the repository.')
    print('Start with: ./macos/service.sh start')


if __name__ == '__main__':
    main()
