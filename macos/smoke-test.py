#!/usr/bin/env python3
"""Exercise the official binary with isolated data and loopback-only fixture sources."""
import argparse
from functools import partial
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('SUMIDOKU_SERVER_BINARY', Path.home() / 'Library/Application Support/Sumidoku/bin/sumidoku-server'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hold', action='store_true', help='Keep the disposable dashboard open until Enter.')
    args = parser.parse_args()
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', 3301))
    with tempfile.TemporaryDirectory(prefix='sumidoku-smoke-') as temporary:
        root = Path(temporary)
        assets = root / 'assets'
        assets.mkdir()
        package = assets / 'example.aix'
        fixture = ROOT / 'crates/wasm/tests/fixtures/example'
        with zipfile.ZipFile(package, 'w') as archive:
            for name in ['source.json', 'main.wasm']:
                archive.write(fixture / name, 'Payload/' + name)
        class QuietHandler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_):
                pass
        repo = http.server.ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(assets)))
        threading.Thread(target=repo.serve_forever, daemon=True).start()
        repo_url = f'http://127.0.0.1:{repo.server_port}/index.json'
        (assets / 'index.json').write_text(json.dumps({'name': 'Disposable fixture repository', 'sources': [{
            'id': 'en.example-source', 'name': 'Example Source', 'version': 1,
            'downloadURL': 'example.aix', 'languages': ['en'], 'contentRating': 0,
        }]}))
        process = None
        log = (root / 'server.log').open('w')
        def request(route, data=None, method=None, raw=False):
            if data is not None and not isinstance(data, bytes):
                data = json.dumps(data).encode()
            req = urllib.request.Request('http://127.0.0.1:3301' + route, data=data,
                                         method=method, headers={'Content-Type': 'application/octet-stream' if raw else 'application/json'})
            try:
                with urllib.request.urlopen(req, timeout=20) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors='replace')
                if error.code != 400:
                    print(f'{route}: HTTP {error.code}: {detail}', flush=True)
                raise
        def stop():
            nonlocal process
            if process and process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            process = None
        def start(name):
            nonlocal process
            directory = root / name
            directory.mkdir(exist_ok=True)
            (directory / 'config.toml').write_text('\n'.join([
                'addr = "127.0.0.1:3301"', 'auto_download_new_chapters = false',
                'auto_download_limit = 0', 'update_interval_hours = 0',
                'backup_enabled = true', 'backup_interval_hours = 24',
                f'backup_dir = {json.dumps(str(directory / "backups"))}',
                f'downloads_dir = {json.dumps(str(directory / "downloads"))}',
            ]) + '\n')
            process = subprocess.Popen([str(BINARY), '--config-dir', str(directory)], cwd=directory, stdout=log, stderr=log)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('Fixture server exited; inspect its temporary log.')
                try:
                    request('/health')
                    return
                except (OSError, urllib.error.URLError):
                    time.sleep(0.2)
            raise RuntimeError('Fixture startup timed out')
        def install_source():
            item = request('/api/v1/source-repos', {'url': repo_url})
            source = request('/api/v1/source-repos/install', {'repoId': item['id'], 'sourceKey': 'en.example-source'})
            return source['id']
        try:
            start('original')
            source_id = install_source()
            request(f'/api/v1/sources/{source_id}/settings', {'verification': 'persisted'}, 'PUT')
            assert request(f'/api/v1/sources/{source_id}/settings')['values']['verification'] == 'persisted'
            aib = (ROOT / 'crates/server/tests/fixtures/example.aib').read_bytes()
            preview = request('/api/v1/backups/import/aidoku?dryRun=true', aib, raw=True)
            assert preview['dryRun'] is True and preview['imported']['library'] == 2
            assert request('/api/v1/library')['entries'] == []
            imported = request('/api/v1/backups/import/aidoku', aib, raw=True)
            assert imported['imported']['library'] == 2 and imported['skipped']
            exported = request('/api/v1/backups/document')
            assert len(exported['library']) == 2 and exported['progress'] and exported['categories']
            assert any(p['lastPageRead'] > 0 for p in exported['progress'])
            # Bad input must leave the portable state unchanged, apart from export time.
            try:
                request('/api/v1/backups/document', {'version': 999, 'library': []})
                raise AssertionError('Unknown backup version accepted')
            except urllib.error.HTTPError as error:
                assert error.code == 400
            assert request('/api/v1/backups/document')['library'] == exported['library']
            stop()
            start('original')
            assert request('/api/v1/backups/document')['library'] == exported['library']
            assert request(f'/api/v1/sources/{source_id}/settings')['values']['verification'] == 'persisted'
            assert len(request('/api/v1/source-repos')) == 1
            stop()
            start('restored')
            restored_source = install_source()
            request('/api/v1/backups/document', exported)
            restored = request('/api/v1/backups/document')
            for section in ['library', 'categories', 'progress', 'sourceSettings']:
                assert restored[section] == exported[section], section
            assert request(f'/api/v1/sources/{restored_source}/settings')['values']['verification'] == 'persisted'
            assert request('/api/v1/downloads') == []
            assert not list(root.rglob('*.cbz'))
            assert not list((root / 'restored/downloads').rglob('*'))
            print('PASS: source repository/install/settings; .aib dry-run and import; missing-source reports;', flush=True)
            print('JSON export/restore; categories/page progress; invalid-backup rejection; restart persistence;', flush=True)
            print('zero downloads. All data is disposable; the permanent library was not used.', flush=True)
            if args.hold:
                print('Disposable dashboard: http://127.0.0.1:3301 — press Enter to clean up.', flush=True)
                input()
        finally:
            stop()
            repo.shutdown()
            repo.server_close()
            log.close()


if __name__ == '__main__':
    main()
