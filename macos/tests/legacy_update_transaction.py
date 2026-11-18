"""Paired app/server activation contract. No downloader or unsigned-install bypass.

Sparkle archive authentication precedes this stage. Production bundle validation
also requires Developer ID/notarization. This is exercised through injected,
disposable service fixtures; automatic Sparkle handoff remains disabled until a
signed end-to-end distribution run certifies termination/relaunch and recovery.
"""
from pathlib import Path
from contextlib import closing
import hashlib
import json
import os
import plistlib
import platform
import re
import shutil
import sqlite3
import subprocess
import uuid
from datetime import datetime, timezone


class UpdateError(Exception):
    pass


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def version(raw):
    match = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', raw)
    if not match:
        raise UpdateError('Unsupported installation version.')
    return tuple(map(int, match.groups()))


def schema(config):
    with closing(sqlite3.connect(f'file:{Path(config) / "sumidoku.db"}?mode=ro', uri=True)) as db:
        return db.execute('SELECT COALESCE(MAX(version),0) FROM _sqlx_migrations').fetchone()[0]


def fingerprint(config):
    value = hashlib.sha256()
    with closing(sqlite3.connect(f'file:{Path(config) / "sumidoku.db"}?mode=ro', uri=True)) as db:
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise UpdateError('Database integrity verification failed.')
        for table in ['user', 'manga_user', 'chapter_user', 'category', 'category_manga', 'source', 'source_setting']:
            value.update(table.encode())
            for row in sorted(repr(row) for row in db.execute(f'SELECT * FROM {table}')):
                value.update(row.encode())
        for row in db.execute("SELECT key,value FROM setting WHERE key LIKE 'backup.%' OR key LIKE 'download%' ORDER BY key"):
            value.update(repr(row).encode())
    return value.hexdigest()


def verify_developer_bundle(app, team):
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise UpdateError('A trusted Developer ID team is required.')
    try:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
        signed = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(app)], check=True, capture_output=True, text=True).stderr
        if f'TeamIdentifier={team}\n' not in signed or 'Authority=Developer ID Application:' not in signed:
            raise UpdateError('The release is not signed by the configured Developer ID team.')
        subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', str(app)], check=True, capture_output=True)
        for binary in [app/'Contents/MacOS/Sumidoku',app/'Contents/Resources/sumidoku-server']:
            subprocess.run(['/usr/bin/lipo','-verify_arch',platform.machine(),str(binary)],check=True,capture_output=True)
    except subprocess.CalledProcessError as error:
        raise UpdateError('Release signature or Gatekeeper assessment failed.') from error


def validate_bundle(app, installed_version, current_schema, team, verify=verify_developer_bundle):
    app = Path(app).resolve()
    verify(app, team)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.sumidoku.desktop':
        raise UpdateError('The update belongs to a different application.')
    minimum=info.get('LSMinimumSystemVersion')
    if not isinstance(minimum,str) or not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?',minimum):
        raise UpdateError('Unknown minimum macOS compatibility.')
    def os_version(value): return tuple((list(map(int,value.split('.')))+[0,0,0])[:3])
    if os_version(minimum)>os_version(platform.mac_ver()[0] or '0.0.0'):
        raise UpdateError('This release requires a newer macOS version.')
    if version(info['CFBundleShortVersionString']) <= version(installed_version):
        raise UpdateError('Application downgrades and repeated installations are rejected.')
    manifest = json.loads((app / 'Contents/Resources/server-build.json').read_text())
    payload = app / 'Contents/Resources/sumidoku-server'
    if not payload.resolve().is_relative_to(app) or manifest.get('variant') != 'fork' or digest(payload) != manifest.get('sha256'):
        raise UpdateError('The matching server payload failed verification.')
    target_schema = manifest.get('databaseSchemaVersion')
    if type(target_schema) is not int or target_schema < current_schema:
        raise UpdateError('Unknown database compatibility or a database downgrade was rejected.')
    return manifest


class UpdateTransaction:
    def __init__(self, *, config, backups, application, runtime, agent, service, health_and_login, installed_version, team, verify=verify_developer_bundle):
        self.config, self.backups = Path(config), Path(backups)
        if self.backups.resolve() == self.config.resolve() or self.config.resolve() in self.backups.resolve().parents:
            raise UpdateError('Recovery snapshots must be outside the server configuration directory.')
        self.application, self.runtime, self.agent = Path(application), Path(runtime), Path(agent)
        self.service, self.health_and_login = service, health_and_login
        self.installed_version, self.team, self.verify = installed_version, team, verify

    def apply(self, payload, cancelled=lambda: False):
        payload = Path(payload)
        old_schema = schema(self.config)
        manifest = validate_bundle(payload, self.installed_version, old_schema, self.team, self.verify)
        if cancelled():
            raise UpdateError('Update cancelled before stopping the server.')
        self.service('stop')
        recovery = self.backups / ('ApplicationUpdate-' + uuid.uuid4().hex)
        previous = self.application.with_name('.Sumidoku-previous-' + uuid.uuid4().hex + '.app')
        staged = self.application.with_name('.Sumidoku-staged-' + uuid.uuid4().hex + '.app')
        replaced = False
        mutated = False
        journal = {'phase': 'preparing', 'version':plistlib.loads((payload/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], 'date':datetime.now(timezone.utc).isoformat(), 'recovery': str(recovery), 'previousSchema': old_schema,
                   'targetSchema': manifest['databaseSchemaVersion']}
        def record(phase):
            journal['phase'] = phase
            path = recovery / 'update-journal.json'
            path.write_text(json.dumps(journal, indent=2)+'\n'); path.chmod(0o600)
        try:
            before = fingerprint(self.config)
            recovery.mkdir(parents=True, mode=0o700)
            shutil.copytree(self.config, recovery / 'Server')
            if fingerprint(recovery / 'Server') != before:
                raise UpdateError('Recovery snapshot verification failed.')
            shutil.copytree(self.application, recovery / 'PreviousClient.app', symlinks=True)
            shutil.copy2(self.runtime, recovery / 'previous-server')
            shutil.copy2(self.agent, recovery / 'LaunchAgent.plist')
            record('snapshot-verified')
            if cancelled():
                raise UpdateError('Update cancelled; the current installation was preserved.')
            # No service/database path is changed, and no second job is created.
            shutil.copytree(payload, staged, symlinks=True)
            temporary = self.runtime.with_name('.sumidoku-server-update-' + uuid.uuid4().hex)
            shutil.copyfile(payload / 'Contents/Resources/sumidoku-server', temporary)
            temporary.chmod(0o700)
            os.replace(temporary, self.runtime); mutated = True
            os.replace(self.application, previous)
            os.replace(staged, self.application); replaced = True
            record('artifacts-replaced')
            self.service('start')
            self.health_and_login()
            if schema(self.config) != manifest['databaseSchemaVersion'] or fingerprint(self.config) != before:
                raise UpdateError('Library/authentication integrity changed; inspect the retained recovery snapshot.')
            record('verified')
            shutil.rmtree(previous)
            return recovery
        except Exception:
            self.service('stop')
            # Never automatically restore/downgrade a database. A migrated or
            # changed database needs explicit review, even when a copy exists.
            unchanged = not mutated or (schema(self.config) == old_schema and fingerprint(self.config) == before)
            if unchanged:
                if mutated:
                    shutil.copy2(recovery / 'previous-server', self.runtime)
                    self.runtime.chmod(0o700)
                if previous.exists():
                    if self.application.exists(): shutil.rmtree(self.application)
                    os.replace(previous, self.application)
                if staged.exists(): shutil.rmtree(staged)
                if recovery.exists():
                    try: record('failed-restored-without-database-rollback')
                    except OSError: pass
                self.service('start')
            elif recovery.exists():
                record('manual-recovery-required-service-stopped')
            raise
