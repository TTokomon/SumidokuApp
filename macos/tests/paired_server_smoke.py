#!/usr/bin/env python3
"""Real disposable LaunchAgent/server round trip; never controls the installed job."""
import base64
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid
import zipfile
ROOT=Path(__file__).resolve().parents[2]
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    with tempfile.TemporaryDirectory(prefix='sumidoku-paired-smoke-') as temporary:
        root=Path(str(Path(temporary).resolve()).replace('/private/var/','/var/',1));config=root/'Server';config.mkdir();backups=root/'Backups';backups.mkdir();books=root/'Books/Fixture';books.mkdir(parents=True)
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        assert port!=3000
        password=secrets.token_urlsafe(24);label='app.sumidoku.fixture.'+uuid.uuid4().hex;domain=f'gui/{os.getuid()}'
        (config/'config.toml').write_text(f'addr = "127.0.0.1:{port}"\ndownloads_dir = '+json.dumps(str(root/'Downloads'))+'\nbackup_dir = '+json.dumps(str(backups))+'\nauto_download_new_chapters = false\nauto_download_limit = 0\nupdate_interval_hours = 0\nrepo_refresh_interval_hours = 0\nbackup_enabled = false\n[auth]\nusername = "fixture-owner"\npassword = '+json.dumps(password)+'\n');(config/'config.toml').chmod(0o600)
        pixel=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1kAAAAASUVORK5CYII=')
        with zipfile.ZipFile(books/'Chapter 01.cbz','w') as archive:
            archive.writestr('ComicInfo.xml','<ComicInfo><Title>Fixture</Title><Series>Fixture</Series></ComicInfo>');archive.writestr('001.png',pixel)
        bin_dir=root/'bin';bin_dir.mkdir();runtime=bin_dir/'server';runner=bin_dir/'runner.sh';shutil.copy2(ROOT/'macos/run-server.sh',runner)
        agent=root/'agent.plist';agent.write_bytes(plistlib.dumps({'Label':label,'ProgramArguments':['/bin/bash',str(runner),str(config),str(runtime)],'KeepAlive':True,'RunAtLoad':True,'StandardOutPath':str(root/'server.log'),'StandardErrorPath':str(root/'server.log')}))
        def app(name,version,build,binary):
            app=root/name/'Sumidoku.app';resources=app/'Contents/Resources';resources.mkdir(parents=True);macos=app/'Contents/MacOS';macos.mkdir()
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.sumidoku.desktop','CFBundleExecutable':'Sumidoku','CFBundlePackageType':'APPL','SumidokuCoordinatedUpdateProtocolVersion':1,'CFBundleVersion':str(build),'CFBundleShortVersionString':version.split('-')[0],'SumidokuReleaseVersion':version,'LSMinimumSystemVersion':'13.0'}))
            client=macos/'Sumidoku';client.write_text('#!/bin/sh\nprintf "%s\\n" '+repr(version)+' >> '+"'"+str(root/'client-launches.log')+"'"+'\n');client.chmod(0o700)
            shutil.copy2(binary,resources/'sumidoku-server');server_hash=digest(resources/'sumidoku-server')
            (resources/'server-build.json').write_text(json.dumps({'variant':'fork','featureSet':'source-integrations-v1','sha256':server_hash,'databaseSchemaVersion':37,'sourceRevision':'a'*40}))
            entry={'version':version,'build':build,'channel':'beta' if 'beta' in version else 'stable','url':f'https://github.com/TTokomon/SumidokuApp/releases/download/desktop-v{version}/Sumidoku-Desktop-{version}-macOS-arm64.zip','length':1,'signature':base64.b64encode(bytes(64)).decode(),'sha256':'0'*64,'clientSha256':digest(client),'serverSha256':server_hash,'sourceRevision':'a'*40,'schema':37}
            (root/(name.lower()+'.json')).write_text(json.dumps(entry));return app
        # Read-only executable copies: no user database/configuration is copied.
        stable=app('Stable','1.3.0',6,Path('/Applications/Sumidoku.app/Contents/Resources/sumidoku-server'))
        app('Beta','1.3.1-beta.1',8,ROOT/'dist/fork/sumidoku-server')
        application=root/'Sumidoku.app';shutil.copytree(stable,application,symlinks=True);shutil.copy2(stable/'Contents/Resources/sumidoku-server',runtime)
        # Foundation's Codable URL representation uses absolute file URLs.
        paths={k:p.as_uri() for k,p in {'application':application,'config':config,'backups':backups,'runtime':runtime,'agent':agent,'runner':runner}.items()};paths['port']=port;(root/'paths.json').write_text(json.dumps(paths))
        cookies=http.cookiejar.CookieJar();opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies));base=f'http://127.0.0.1:{port}'
        def request(path,body=None,method=None):
            r=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,method=method,headers={'Content-Type':'application/json'})
            with opener.open(r,timeout=10) as response:return json.load(response)
        subprocess.run(['launchctl','bootstrap',domain,str(agent)],check=True)
        try:
            for _ in range(150):
                try:request('/health');break
                except OSError:time.sleep(.1)
            request('/api/v1/auth/login',{'username':'fixture-owner','password':password},'POST')
            # Remove the fixture seed; authentication must survive in its hashed database.
            text=(config/'config.toml').read_text();(config/'config.toml').write_text(text.split('[auth]')[0])
            source=request('/api/v1/integrations',{'provider':'local','name':'Fixture Local','paths':[str(books.parent)]},'POST')
            request('/api/v1/local/scan',{'sourceId':source['id']},'POST')
            for _ in range(100):
                entries=request(f'/api/v1/sources/{source["id"]}/search',{'query':''},'POST').get('entries',[])
                if entries:break
                time.sleep(.1)
            assert entries,'Fixture scan failed'
            manga=request('/api/v1/manga',{'sourceId':source['id'],'manga':entries[0]},'POST');request('/api/v1/library',{'mangaId':manga['id']},'POST')
            chapters=request(f'/api/v1/manga/{manga["id"]}/chapters');assert chapters
            request(f'/api/v1/chapter/{chapters[0]["id"]}',{'lastPageRead':1,'pageCount':2},'PATCH')
            subprocess.run([str(ROOT/'dist/native/PairedServerSmoke'),str(root),label],input=json.dumps({'username':'fixture-owner','password':password}),text=True,check=True,timeout=120)
        finally:
            assert label.startswith('app.sumidoku.fixture.')
            subprocess.run(['launchctl','bootout',domain+'/'+label],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            for _ in range(100):
                try:request('/health');time.sleep(.1)
                except OSError:break
if __name__=='__main__':main()
