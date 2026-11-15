from contextlib import closing
import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('paired_update',Path(__file__).resolve().parents[1]/'Distribution/update_transaction.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class UpdateTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='sumidoku-update-fixture-')
        self.root=Path(self.temporary.name);self.config=self.root/'Server';self.config.mkdir()
        self.backups=self.root/'Backups';self.backups.mkdir()
        with closing(sqlite3.connect(self.config/'sumidoku.db')) as db, db:
            for table in ['user','manga_user','chapter_user','category','category_manga','source','source_setting']:
                db.execute(f'CREATE TABLE {table}(id INTEGER,value TEXT)')
                db.execute(f'INSERT INTO {table} VALUES(1,?)',('fixture-'+table,))
            db.execute('CREATE TABLE setting(key TEXT,value TEXT)')
            db.executemany('INSERT INTO setting VALUES(?,?)',[('backup.enabled','true'),('backup.intervalHours','24'),('downloads.format','cbz')])
            db.execute('CREATE TABLE _sqlx_migrations(version INTEGER)');db.execute('INSERT INTO _sqlx_migrations VALUES(1)')
        (self.config/'source-package.aix').write_bytes(b'fixture-source')
        self.app=self.make_app('installed.app','1.0.0',b'old-server')
        self.payload=self.make_app('update.app','1.1.0',b'new-server')
        self.runtime=self.root/'sumidoku-server-fork';self.runtime.write_bytes(b'old-server')
        self.agent=self.root/'agent.plist';self.agent.write_bytes(b'unchanged-managed-job')
        self.events=[];self.before=module.fingerprint(self.config)
    def tearDown(self): self.temporary.cleanup()
    def make_app(self,name,version,payload,schema=1):
        app=self.root/name;resources=app/'Contents/Resources';resources.mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.sumidoku.desktop','CFBundleShortVersionString':version,'LSMinimumSystemVersion':'13.0'}))
        (resources/'sumidoku-server').write_bytes(payload)
        (resources/'server-build.json').write_text(json.dumps({'variant':'fork','sha256':module.digest(resources/'sumidoku-server'),'databaseSchemaVersion':schema}))
        return app
    def transaction(self,health=lambda:None,service=None,verify=lambda app,team:None):
        return module.UpdateTransaction(config=self.config,backups=self.backups,application=self.app,runtime=self.runtime,agent=self.agent,service=service or self.events.append,health_and_login=health,installed_version='1.0.0',team='ABCDEFGHIJ',verify=verify)
    def test_paired_update_preserves_database_sources_settings_and_agent(self):
        called=[]
        recovery=self.transaction(health=lambda:called.append('health-and-login')).apply(self.payload)
        self.assertEqual(called,['health-and-login']);self.assertEqual(self.events,['stop','start'])
        self.assertEqual(self.runtime.read_bytes(),b'new-server')
        self.assertEqual(module.fingerprint(self.config),self.before)
        self.assertEqual((self.config/'source-package.aix').read_bytes(),b'fixture-source')
        self.assertEqual(self.agent.read_bytes(),b'unchanged-managed-job')
        self.assertEqual((recovery/'previous-server').read_bytes(),b'old-server')
        self.assertEqual(json.loads((recovery/'update-journal.json').read_text())['phase'],'verified')
        self.assertEqual(recovery.stat().st_mode & 0o777,0o700)
    def test_unsigned_bundle_rejected_by_actual_developer_verifier_before_stop(self):
        with self.assertRaises(module.UpdateError): self.transaction(verify=module.verify_developer_bundle).apply(self.payload)
        self.assertEqual(self.events,[])
    def test_tampered_matching_server_is_rejected(self):
        (self.payload/'Contents/Resources/sumidoku-server').write_bytes(b'tampered')
        with self.assertRaises(module.UpdateError): self.transaction().apply(self.payload)
        self.assertEqual(self.events,[])
    def test_database_downgrade_is_rejected_without_mutation(self):
        manifest=self.payload/'Contents/Resources/server-build.json';value=json.loads(manifest.read_text());value['databaseSchemaVersion']=0;manifest.write_text(json.dumps(value))
        with self.assertRaises(module.UpdateError): self.transaction().apply(self.payload)
        self.assertEqual(self.events,[]);self.assertEqual(module.fingerprint(self.config),self.before)
    def test_cancel_before_stopping_preserves_live_installation(self):
        with self.assertRaises(module.UpdateError): self.transaction().apply(self.payload,cancelled=lambda:True)
        self.assertEqual(self.events,[])
    def test_cancel_after_snapshot_restarts_old_service(self):
        calls=[]
        def cancel(): calls.append(True);return len(calls)==2
        with self.assertRaises(module.UpdateError): self.transaction().apply(self.payload,cancelled=cancel)
        self.assertEqual(self.events,['stop','stop','start']);self.assertEqual(self.runtime.read_bytes(),b'old-server')
    def test_failed_health_restores_pair_without_rolling_back_database(self):
        def failure(): raise module.UpdateError('fixture login verification failure')
        with self.assertRaises(module.UpdateError): self.transaction(health=failure).apply(self.payload)
        self.assertEqual(self.runtime.read_bytes(),b'old-server');self.assertEqual(module.fingerprint(self.config),self.before)
        info=plistlib.loads((self.app/'Contents/Info.plist').read_bytes());self.assertEqual(info['CFBundleShortVersionString'],'1.0.0')
        self.assertEqual(self.events,['stop','start','stop','start'])
    def test_failed_migrated_database_stays_stopped_for_review(self):
        manifest=self.payload/'Contents/Resources/server-build.json';value=json.loads(manifest.read_text());value['databaseSchemaVersion']=2;manifest.write_text(json.dumps(value))
        def start(action):
            self.events.append(action)
            if action=='start':
                with closing(sqlite3.connect(self.config/'sumidoku.db')) as db, db: db.execute('INSERT INTO _sqlx_migrations VALUES(2)')
        def failure(): raise module.UpdateError('fixture post-migration failure')
        with self.assertRaises(module.UpdateError): self.transaction(health=failure,service=start).apply(self.payload)
        self.assertEqual(module.schema(self.config),2);self.assertEqual(self.events,['stop','start','stop'])
        recovery=next(self.backups.glob('ApplicationUpdate-*'))
        self.assertEqual(module.schema(recovery/'Server'),1)
        self.assertEqual(json.loads((recovery/'update-journal.json').read_text())['phase'],'manual-recovery-required-service-stopped')
    def test_backup_copy_failure_resumes_current_service(self):
        with patch.object(module.shutil,'copytree',side_effect=OSError('fixture disk-full failure')):
            with self.assertRaises(OSError): self.transaction().apply(self.payload)
        self.assertEqual(self.events,['stop','stop','start']);self.assertEqual(module.fingerprint(self.config),self.before)
    def test_incompatible_macos_is_rejected_before_stopping(self):
        info=self.payload/'Contents/Info.plist';value=plistlib.loads(info.read_bytes());value['LSMinimumSystemVersion']='999.0';info.write_bytes(plistlib.dumps(value))
        with self.assertRaises(module.UpdateError): self.transaction().apply(self.payload)
        self.assertEqual(self.events,[])
    def test_unknown_version_and_application_identity_rejected(self):
        info=self.payload/'Contents/Info.plist';value=plistlib.loads(info.read_bytes());value['CFBundleIdentifier']='other.application';info.write_bytes(plistlib.dumps(value))
        with self.assertRaises(module.UpdateError): self.transaction().apply(self.payload)
        self.assertEqual(self.events,[])

if __name__=='__main__': unittest.main()
