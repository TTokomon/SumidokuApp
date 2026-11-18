#!/usr/bin/env python3
"""Actual native app/helper/server round trip in a compiled disposable scope.

Requires Stable/Beta .app bundles built with COMMUNITY_E2E and an ephemeral test
key. Never uses production credentials, data, port, job or application identity.
"""
import argparse
import base64
import hashlib
import http.cookiejar
import http.server
import json
import os
from pathlib import Path
import plistlib
import secrets
import sqlite3
import shutil
import subprocess
import threading
import time
import urllib.request
import zipfile

REPO=Path(__file__).resolve().parents[2]
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(root):
    root=root.resolve();assert root.name.startswith('sumidoku-community-e2e-')
    scope=json.loads((root/'scope.json').read_text());label=scope['label'];port=scope['port'];assert label.startswith('app.sumidoku.fixture.') and port!=3000
    stable=root/'Stable/Sumidoku.app';beta=root/'Beta/Sumidoku.app'
    for app in [stable,beta]:
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes());assert info['SumidokuEndToEndFixture'] and info['CFBundleIdentifier']==label+'.desktop'
    distribution=root/'Distribution';distribution.mkdir()
    sparkle=Path('/private/tmp/sumidoku-sparkle-2.10.1')
    secret=(root/'test-signing-seed').read_text()
    def sign(p):
        return subprocess.run([str(sparkle/'bin/sign_update'),'--ed-key-file','-','-p',str(p)],input=secret+'\n',capture_output=True,text=True,check=True).stdout.strip()
    entries=[]
    for app in [stable,beta]:
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes());version=info['SumidokuReleaseVersion'];archive=distribution/f'Sumidoku-Desktop-{version}-macOS-arm64.zip'
        subprocess.run(['ditto','-c','-k','--norsrc','--noextattr','--keepParent',str(app),str(archive)],check=True)
        manifest=json.loads((app/'Contents/Resources/server-build.json').read_text())
        entries.append({'version':version,'build':int(info['CFBundleVersion']),'channel':'beta' if 'beta' in version else 'stable','url':f'https://github.com/TTokomon/SumidokuApp/releases/download/desktop-v{version}/{archive.name}','length':archive.stat().st_size,'signature':sign(archive),'sha256':digest(archive),'clientSha256':digest(app/'Contents/MacOS/Sumidoku'),'serverSha256':digest(app/'Contents/Resources/sumidoku-server'),'sourceRevision':manifest['sourceRevision'],'schema':manifest['databaseSchemaVersion']})
    catalog=distribution/'desktop-releases.json';catalog.write_text(json.dumps({'format':1,'releases':entries},separators=(',',':')));Path(str(catalog)+'.sig').write_text(sign(catalog)+'\n')
    (root/'releases.json').write_text(json.dumps([{'id':n+1,'tag_name':'desktop-v'+e['version'],'name':e['version'],'html_url':'https://github.com/TTokomon/SumidokuApp/releases/tag/desktop-v'+e['version'],'draft':False,'prerelease':e['channel']=='beta','assets':[{'name':Path(e['url']).name,'browser_download_url':e['url']}]} for n,e in enumerate(entries)]))
    home=root/'Home';support=home/'Library/Application Support/Sumidoku';bin_dir=support/'bin';bin_dir.mkdir(parents=True)
    library=root/'Library';config=library/'Server';config.mkdir(parents=True);downloads=library/'Downloads';downloads.mkdir();backups=library/'Backups';backups.mkdir()
    (downloads/'preserved.fixture').write_bytes(b'existing downloaded fixture; never fetched by updater');(backups/'preserved.backup').write_bytes(b'existing backup fixture')
    protected={str(p):digest(p) for p in [downloads/'preserved.fixture',backups/'preserved.backup']}
    password=secrets.token_urlsafe(32);session={'username':'fixture-owner','password':password};(root/'session.json').write_text(json.dumps(session));(root/'session.json').chmod(0o600)
    (config/'config.toml').write_text(f'addr = "127.0.0.1:{port}"\ndownloads_dir = '+json.dumps(str(downloads))+'\nbackup_dir = '+json.dumps(str(backups))+'\nauto_download_new_chapters = false\nauto_download_limit = 0\nupdate_interval_hours = 0\nrepo_refresh_interval_hours = 0\nbackup_enabled = true\nbackup_interval_hours = 24\n[auth]\nusername = "fixture-owner"\npassword = '+json.dumps(password)+'\n');(config/'config.toml').chmod(0o600)
    (config/'.aidoku-community-list-initialized').write_text('fixture: avoid external subscription traffic\n')
    books=root/'Books/Fixture';books.mkdir(parents=True)
    pixel=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1kAAAAASUVORK5CYII=')
    with zipfile.ZipFile(books/'Chapter 01.cbz','w') as archive:archive.writestr('001.png',pixel)
    runner=bin_dir/'run-server.sh';runtime=bin_dir/'sumidoku-server-fork';shutil.copy2(stable/'Contents/Resources/run-server.sh',runner);shutil.copy2(stable/'Contents/Resources/sumidoku-server',runtime)
    application=root/'Installed/Sumidoku.app';application.parent.mkdir();shutil.copytree(stable,application,symlinks=True)
    agent=home/f'Library/LaunchAgents/{label}.plist';agent.parent.mkdir(parents=True)
    agent.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':['/bin/bash',str(runner),str(config),str(runtime)],'RunAtLoad':True,'KeepAlive':True,'StandardOutPath':str(root/'server.log'),'StandardErrorPath':str(root/'server-error.log')}))
    (support/'desktop-library.json').write_text(json.dumps({k:v.as_uri() for k,v in {'root':library,'config':config,'downloads':downloads,'backups':backups}.items()}))
    cookies=http.cookiejar.CookieJar();opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies));base=f'http://127.0.0.1:{port}'
    def request(path,body=None,method=None):
        req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json'})
        with opener.open(req,timeout=10) as response:return json.load(response)
    def wait(predicate,description,timeout=100):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            try:
                result=predicate()
                if result:return result
            except (OSError,ValueError,KeyError):pass
            time.sleep(.25)
        raise AssertionError(description+'; last status: '+(root/'status.json').read_text() if (root/'status.json').exists() else description)
    def status(version,previous=None):
        value=json.loads((root/'status.json').read_text())
        return value if value['version']==version and value['signedIn'] and value['canInstall'] and value['window'] and not value['loading'] and (previous is None or value['pid']!=previous) else None
    def journals_verified(n):
        records=list(backups.glob('ApplicationUpdate-*/update-journal.json'))
        return len(records)==n and all(json.loads(p.read_text())['phase']=='verified' for p in records)
    def reading():
        doc=request('/api/v1/backups/document');return json.dumps({k:doc.get(k,[]) for k in ['library','progress','categories']},sort_keys=True)
    class FixtureIndex(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/index.json':
                self.send_error(404)
                return
            payload = json.dumps({'name': 'Roundtrip Fixture List', 'sources': [{
                'id': 'en.roundtrip-fixture', 'name': 'Roundtrip Fixture', 'version': 1,
                'downloadURL': 'fixture.aix', 'languages': ['en'], 'contentRating': 0,
            }]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *args):
            pass

    repo = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FixtureIndex)
    threading.Thread(target=repo.serve_forever, daemon=True).start()
    domain=f'gui/{os.getuid()}'
    try:
        subprocess.run(['launchctl','bootstrap',domain,str(agent)],check=True)
        wait(lambda:request('/health'),'Fixture server health')
        request('/api/v1/auth/login',session,'POST');(config/'config.toml').write_text((config/'config.toml').read_text().split('[auth]')[0])
        repo_url = f'http://127.0.0.1:{repo.server_port}/index.json'
        subscription = request('/api/v1/source-repos', {'url': repo_url}, 'POST')
        preferences = {'autoRefreshLists': False, 'autoUpdatePackages': False}
        request('/api/v1/source-repos/preferences', preferences, 'PUT')

        def check_external_sources():
            rows = request('/api/v1/source-repos')
            assert any(row['id'] == subscription['id'] and row['name'] == 'Roundtrip Fixture List' and row['sourceCount'] == 1 for row in rows)
            settings = request('/api/v1/source-repos/preferences')
            assert all(settings[key] is value for key, value in preferences.items())

        check_external_sources()
        source=request('/api/v1/integrations',{'provider':'local','name':'Fixture Local','paths':[str(books.parent)]},'POST');request('/api/v1/local/scan',{'sourceId':source['id']},'POST')
        found=wait(lambda:request(f'/api/v1/sources/{source["id"]}/search',{'query':''},'POST').get('entries',[]),'Fixture scan')
        manga=request('/api/v1/manga',{'sourceId':source['id'],'manga':found[0]},'POST');request('/api/v1/library',{'mangaId':manga['id']},'POST');chapters=request(f'/api/v1/manga/{manga["id"]}/chapters');assert chapters
        downloaded=downloads/'Fixture.cbz';shutil.copy2(books/'Chapter 01.cbz',downloaded);protected[str(downloaded)]=digest(downloaded)
        with sqlite3.connect(config/'sumidoku.db') as database:
            owner=database.execute('SELECT id FROM user WHERE username=?',(session['username'],)).fetchone()[0]
            database.execute("INSERT INTO download(chapter_id,user_id,status,format,path) VALUES(?,?,'finished','cbz',?)",(chapters[0]['id'],owner,str(downloaded)))
        route=f'/api/v1/chapter/{chapters[0]["id"]}';request(route,{'lastPageRead':1,'pageCount':3},'PATCH');original=reading()
        subprocess.run(['open','-n',str(application)],check=True)
        first=wait(lambda:status(entries[0]['version']),'Stable native window/login/install readiness')
        (root/'session.json').rename(root/'test-fixture-account.private.json')
        (root/'command.txt').write_text('update');second=wait(lambda:status(entries[1]['version'],first['pid']),'Beta real helper relaunch', timeout=300)
        wait(lambda:journals_verified(1),'Verified Beta handoff journal');assert second['canRestore'];assert reading()==original
        assert digest(runtime)==entries[1]['serverSha256'];check_external_sources()
        request(route,{'lastPageRead':2,'pageCount':3},'PATCH');advanced=reading();assert advanced!=original
        (root/'command.txt').write_text('restore');third=wait(lambda:status(entries[0]['version'],second['pid']),'Stable real helper restore/relaunch', timeout=300)
        wait(lambda:journals_verified(2),'Verified Stable restore journal');assert reading()==advanced;assert digest(runtime)==entries[0]['serverSha256'];check_external_sources()
        with sqlite3.connect(config/'sumidoku.db') as database:
            assert database.execute("SELECT chapter_id,status,path FROM download").fetchall()==[(chapters[0]['id'],'finished',str(downloaded))]
        assert all(digest(Path(p))==h for p,h in protected.items());assert 'backup_enabled = true' in (config/'config.toml').read_text()
        assert request('/api/v1/auth/login',session,'POST').get('username')==session['username'] or request('/api/v1/auth/status').get('username')==session['username']
        listeners=subprocess.check_output(['lsof','-nP',f'-tiTCP:{port}','-sTCP:LISTEN'],text=True).split();assert len(listeners)==1
        receipt={'format':1,'status':'passed','kind':'community-disposable-native-roundtrip','stable':entries[0],'beta':entries[1],'preserved':['library','account login','advanced reading progress','local source','external source subscription and preferences','downloads without new automatic jobs','existing backup','backup schedule'],'nativePids':[first['pid'],second['pid'],third['pid']],'testTransport':'compiled local signed-byte fixture; live HTTPS and Gatekeeper first-run not certified','productionInstallationTouched':False,'relaunchAuthentication':'persisted WKWebView cookies; credential injection removed after first launch'}
        (root/'roundtrip-result.json').write_text(json.dumps(receipt,indent=2)+'\n');print('PASS: actual community Stable → Beta → Restore Stable, real native windows/helper/server, preserved advanced progress/account/downloads/backups; no production installation touched')
    finally:
        repo.shutdown();repo.server_close()
        (root/'command.txt').write_text('quit');time.sleep(1)
        subprocess.run(['launchctl','bootout',domain+'/'+label],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        # Preserve disposable installations and evidence for review. Private fixture
        # credentials/key remain in the 0700 test root; never copy them to evidence.
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);args=parser.parse_args();main(args.root)
