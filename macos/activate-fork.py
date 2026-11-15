#!/usr/bin/env python3
"""Explicit, backup-first local activation of a separately named fork binary."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import sqlite3
import subprocess
import time
from urllib.parse import unquote, urlparse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_url(raw):
    parsed = urlparse(raw)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        raise RuntimeError('Library descriptor must contain local file URLs.')
    return Path(unquote(parsed.path))


def identity(config):
    with sqlite3.connect(f'file:{config / "sumidoku.db"}?mode=ro', uri=True) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        value = hashlib.sha256()
        for table in ['user', 'manga_user', 'chapter_user', 'category', 'category_manga']:
            rows = sorted(repr(row) for row in db.execute(f'SELECT * FROM {table}'))
            value.update(table.encode() + '\n'.join(rows).encode())
        return value.hexdigest()


def private_copy(source, target):
    if source.is_dir():
        shutil.copytree(source, target)
    elif source.exists():
        shutil.copy2(source, target)
        target.chmod(0o600)


def service(action):
    subprocess.run(['/bin/bash', str(ROOT / 'macos/service.sh'), action], check=True,
                   stdout=subprocess.DEVNULL)


def prepare_recovery(config, recovery, agent, descriptor, runner, fork):
    if config:
        baseline = identity(config)
        private_copy(config, recovery / 'Server')
        assert identity(recovery / 'Server') == baseline
        private_copy(agent, recovery / 'LaunchAgent.plist')
        private_copy(descriptor, recovery / 'desktop-library.json')
    private_copy(runner, recovery / 'run-server.sh')
    private_copy(fork, recovery / 'previous-fork')
    if Path('/Applications/Sumidoku.app').exists():
        subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', '/Applications/Sumidoku.app', str(recovery / 'PreviousClient.app')], check=True)
    (recovery / 'KEEP-UNTIL-APPROVED.txt').write_text('Private cold recovery copy. Retain until the upgrade is verified and the owner explicitly approves removal. The official cached executable was not replaced.\n')


def main():
    os.umask(0o077)
    home = Path.home()
    support = home / 'Library/Application Support/Sumidoku'
    descriptor = support / 'desktop-library.json'
    agent = home / 'Library/LaunchAgents/app.sumidoku.server.plist'
    runner = support / 'bin/run-server.sh'
    original = support / 'bin/sumidoku-server'
    fork = support / 'bin/sumidoku-server-fork'
    payload = ROOT / 'dist/fork/sumidoku-server'
    app = Path(json.loads((ROOT / 'dist/fork/native-build.json').read_text())['appPath'])
    manifest = json.loads((ROOT / 'dist/fork/server-build.json').read_text())
    assert manifest['variant'] == 'fork' and manifest['sha256'] == digest(payload)
    assert (app / 'Contents/MacOS/Sumidoku').is_file()
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)
    old_hash = digest(original) if original.exists() else None
    config = None
    plist = None
    if descriptor.exists():
        saved = json.loads(descriptor.read_text())
        config = file_url(saved['config'])
        backups = file_url(saved['backups'])
        plist = plistlib.loads(agent.read_bytes())
        args = plist['ProgramArguments']
        if plist['Label'] != 'app.sumidoku.server' or args[:2] != ['/bin/bash', str(runner)] or len(args) < 3 or args[2] != str(config):
            raise RuntimeError('Existing service layout needs review; nothing was replaced.')
        if backups == config or config in backups.parents:
            raise RuntimeError('Recovery destination must be outside the server config root.')
    else:
        if agent.exists() or (support / 'config.toml').exists():
            raise RuntimeError('An existing untracked installation needs review; nothing was replaced.')
        backups = home / 'Library/Application Support/Sumidoku Runtime Recovery'
    # Quit only this client and wait for WebKit's stream to close before stopping.
    if subprocess.run(['/usr/bin/pgrep', '-f', '^/Applications/Sumidoku.app/Contents/MacOS/Sumidoku$'], stdout=subprocess.DEVNULL).returncode == 0:
        subprocess.run(['/usr/bin/osascript', '-e', 'tell application id "app.sumidoku.desktop" to quit'], check=True)
        for _ in range(100):
            if subprocess.run(['/usr/bin/pgrep', '-f', '^/Applications/Sumidoku.app/Contents/MacOS/Sumidoku$'], stdout=subprocess.DEVNULL).returncode != 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('Quit the native client before activating; nothing was replaced.')
    recovery = backups / ('fork-upgrade-' + uuid.uuid4().hex)
    recovery.mkdir(parents=True, mode=0o700)
    if config:
        service('stop')
    try:
        prepare_recovery(config, recovery, agent, descriptor, runner, fork)
    except Exception:
        if config:
            service('start')
        raise
    baseline = identity(config) if config else None
    try:
        fork.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(payload, fork)
        fork.chmod(0o700)
        shutil.copyfile(ROOT / 'macos/run-server.sh', runner)
        runner.chmod(0o700)
        shutil.copyfile(ROOT / 'dist/fork/server-build.json', support / 'server-build.json')
        if config:
            # Explicit requested metadata-only behavior; all other settings remain.
            with sqlite3.connect(config / 'sumidoku.db') as db:
                for key, value in [('auto_download_new_chapters', False), ('auto_download_limit', 0), ('downloads.download_ahead', False)]:
                    db.execute('INSERT INTO setting(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', (key, json.dumps(value)))
            plist['ProgramArguments'] = ['/bin/bash', str(runner), str(config), str(fork)]
            temporary = agent.with_suffix('.new')
            temporary.write_bytes(plistlib.dumps(plist)); temporary.chmod(0o600); temporary.replace(agent)
            service('start')
            with urllib.request.urlopen('http://127.0.0.1:3000/api/v1/version', timeout=10) as response:
                assert json.load(response)['variant'] == 'sumidokuapp-source-integrations'
            assert identity(config) == baseline, 'Account/library/progress changed unexpectedly; recovery retained'
        # Swap only the verified client bundle, after retaining its previous copy.
        if Path('/Applications/Sumidoku.app').exists():
            shutil.rmtree('/Applications/Sumidoku.app')
        subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', str(app), '/Applications/Sumidoku.app'], check=True)
        for attribute in ['com.apple.FinderInfo', 'com.apple.ResourceFork']:
            subprocess.run(['/usr/bin/xattr', '-dr', attribute, '/Applications/Sumidoku.app'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '/Applications/Sumidoku.app'], check=True)
        if old_hash:
            assert digest(original) == old_hash, 'Official binary must remain byte-identical'
    except Exception:
        # Retain every recovery file; restore the prior service and client.
        if config:
            try:
                service('stop')
                shutil.copyfile(recovery / 'LaunchAgent.plist', agent)
                shutil.copyfile(recovery / 'run-server.sh', runner); runner.chmod(0o700)
                service('start')
            except Exception:
                print('Previous runtime needs recovery from the retained private snapshot.')
        if (recovery / 'PreviousClient.app').exists():
            if Path('/Applications/Sumidoku.app').exists():
                shutil.rmtree('/Applications/Sumidoku.app')
            subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', str(recovery / 'PreviousClient.app'), '/Applications/Sumidoku.app'], check=True)
        print(f'Activation failed. Recovery retained: {recovery}')
        raise
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', '/Applications/Sumidoku.app'], check=True)
    subprocess.run(['/usr/bin/open', '/Applications/Sumidoku.app'], check=True)
    print(f'Activated separate fork executable. Private recovery retained: {recovery}')
    print('Official binary, owner account, library/progress, sources and original backups preserved.')


if __name__ == '__main__':
    main()
