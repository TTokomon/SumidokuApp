#!/usr/bin/env python3
"""Apply metadata-only settings through the running local server, then verify readback."""
import json
from pathlib import Path
import tomllib
import urllib.request


def configure():
    config = tomllib.loads((Path.home() / 'Library/Application Support/Sumidoku/config.toml').read_text())
    base = 'http://127.0.0.1:3000'
    def request(route, value=None, token=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        body = json.dumps(value).encode() if value is not None else None
        req = urllib.request.Request(base + route, data=body, headers=headers)
        if route == '/api/v1/settings' and body is not None:
            req.method = 'PUT'
        with urllib.request.urlopen(req, timeout=20) as response:
            return json.load(response)
    token = request('/api/v1/auth/login', config['auth'])['token']
    request('/api/v1/settings', {
        'auto_download_new_chapters': False,
        'auto_download_limit': 0,
        'downloads.download_ahead': False,
        'library.update_interval_hours': 0,
    }, token)
    settings = request('/api/v1/settings', token=token)
    assert settings['download']['autoDownloadNewChapters'] is False
    assert settings['download']['autoDownloadLimit'] == 0
    assert settings['download']['downloadAhead'] is False
    print('Authentication and metadata-only download settings verified by API readback.')
    request('/api/v1/backups/files', token=token)
    print('Scheduled backup endpoint verified.')


if __name__ == '__main__':
    configure()
