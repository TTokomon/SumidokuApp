#!/usr/bin/env python3
"""Render the embedded interface in a disposable WKWebView and localhost server."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
binary = Path(os.environ.get('SUMIDOKU_SERVER_BINARY', ROOT / 'dist/fork/sumidoku-server'))
with tempfile.TemporaryDirectory(prefix='sumidoku-source-ui-') as folder:
    root = Path(folder)
    (root / 'config.toml').write_text('addr = "127.0.0.1:3307"\nauto_download_new_chapters = false\nauto_download_limit = 0\nupdate_interval_hours = 0\nbackup_enabled = false\n')
    driver = root / 'SourceUITests'
    environment = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-framework', 'AppKit', '-framework', 'WebKit', str(ROOT / 'macos/tests/SourceUIRenderTests.swift'), '-o', str(driver)], env=environment, check=True)
    with (root / 'server.log').open('w') as log:
        server = subprocess.Popen([str(binary), '--config-dir', str(root)], cwd=root, stdout=log, stderr=log)
        try:
            for attempt in range(150):
                if server.poll() is not None:
                    raise RuntimeError('Disposable server exited before readiness.')
                try:
                    with urllib.request.urlopen('http://127.0.0.1:3307/health', timeout=1):
                        break
                except OSError:
                    time.sleep(.2)
            else:
                raise RuntimeError('Disposable server readiness timeout.')
            # Keep the visual artifacts outside the disposable database directory.
            output = Path(tempfile.mkdtemp(prefix='sumidoku-source-ui-renders-'))
            subprocess.run([str(driver), 'http://127.0.0.1:3307', str(output)], check=True, timeout=90)
            print('Own-view renders:', output)
        finally:
            server.send_signal(signal.SIGINT)
            try:
                server.wait(timeout=20)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
