#!/usr/bin/env python3
"""Render actual native SwiftUI + web surfaces against a disposable local library."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import urllib.request
import zipfile
from xml.sax.saxutils import escape
ROOT=Path(__file__).resolve().parents[1]
BINARY=Path(os.environ.get('SUMIDOKU_SERVER_BINARY',Path.home()/'Library/Application Support/Sumidoku/bin/sumidoku-server-fork'))
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
with tempfile.TemporaryDirectory(prefix='sumidoku-native-ui-fixture-') as temporary:
    root=Path(temporary);books=root/'Books';books.mkdir();art=root/'Artwork';art.mkdir()
    subprocess.run(['xcrun','swift', '-module-cache-path',str(ROOT/'dist/native/ModuleCache'),str(ROOT/'macos/tests/ComicFixtureGenerator.swift'),str(art)],env=env,check=True)
    names=['Silent Orbit','Paper Cities','After the Rain','Northbound','The Blue Hour','Small Wonders','Night Market','Last Light']
    for i,name in enumerate(names):
        folder=books/name;folder.mkdir()
        (folder/'ComicInfo.xml').write_text(f'<ComicInfo><Title>{escape(name)}</Title><Series>{escape(name)}</Series><Writer>Original Fixture Studio</Writer><Summary>A disposable library used to verify the desktop interface. No personal library or copyrighted manga artwork is used.</Summary><Genre>Adventure</Genre></ComicInfo>')
        for chapter in range(1,4):
            with zipfile.ZipFile(folder/f'Chapter {chapter:02}.cbz','w') as archive:
                archive.write(art/f'cover-{i}.png','001.png')
                for page in range(2,5): archive.write(art/'page.png',f'{page:03}.png')
    (root/'config.toml').write_text('addr = "127.0.0.1:3309"\nauto_download_new_chapters = false\nauto_download_limit = 0\nupdate_interval_hours = 0\nbackup_enabled = false\nwebui_dir = '+json.dumps(str(ROOT/'webui/build'))+'\n')
    app=root/'DesktopRenderTests.app';resources=app/'Contents/Resources';resources.mkdir(parents=True);(app/'Contents/MacOS').mkdir()
    import plistlib,shutil,re
    build_script=(ROOT/'macos/build-app.sh').read_text()
    client_version=re.search(r"'CFBundleShortVersionString': '([^']+)'",build_script).group(1)
    client_build=re.search(r"'CFBundleVersion': '([^']+)'",build_script).group(1)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.sumidoku.desktop-ui-tests','CFBundleExecutable':'DesktopRenderTests','CFBundlePackageType':'APPL','CFBundleShortVersionString':client_version,'CFBundleVersion':client_build,'CFBundleIconFile':'AppIcon.png','NSPrincipalClass':'NSApplication','NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}))
    shutil.copyfile(ROOT/'crates/server/tests/fixtures/example.aib',root/'example.aib')
    shutil.copyfile(ROOT/'macos/service.sh',resources/'service.sh')
    shutil.copyfile(ROOT/'webui/public/icons/icon-512.png',resources/'AppIcon.png')
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-D','NATIVE_UI_TESTS','-module-cache-path',str(ROOT/'dist/native/ModuleCache'),*[str(p) for p in (ROOT/'macos/App').glob('*.swift')],str(ROOT/'macos/tests/DesktopRenderTests.swift'),'-o',str(app/'Contents/MacOS/DesktopRenderTests')],env=env,check=True)
    def request(path,body=None,method=None):
        data=json.dumps(body).encode() if body is not None else None
        req=urllib.request.Request('http://127.0.0.1:3309'+path,data=data,method=method,headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=30) as response:return json.load(response)
    with (root/'server.log').open('w') as log:
        server=subprocess.Popen([str(BINARY),'--config-dir',str(root)],cwd=root,stdout=log,stderr=log,env={k:v for k,v in os.environ.items() if not k.startswith('SUMIDOKU_')})
        try:
            for _ in range(100):
                try:request('/health');break
                except OSError:time.sleep(.2)
            source=request('/api/v1/integrations',{'provider':'local','name':'Local Files Preview','paths':[str(books)]},'POST')
            request('/api/v1/local/scan',{'sourceId':source['id']},'POST')
            entries=[]
            for _ in range(150):
                entries=request(f'/api/v1/sources/{source["id"]}/search',{'query':''},'POST').get('entries',[])
                if len(entries)>=8:break
                time.sleep(.2)
            assert len(entries)>=8,'Local fixture scan did not finish'
            first=None
            category=request('/api/v1/categories',{'name':'Currently Reading'},'POST')
            for i,entry in enumerate(entries):
                manga=request('/api/v1/manga',{'sourceId':source['id'],'manga':entry},'POST')
                request('/api/v1/library',{'mangaId':manga['id']},'POST')
                if i<3:request(f'/api/v1/manga/{manga["id"]}/categories',{'categoryIds':[category['id']]},'PUT')
                chapters=request(f'/api/v1/manga/{manga["id"]}/chapters')
                if chapters:
                    request(f'/api/v1/chapter/{chapters[0]["id"]}',{'lastPageRead':2,'pageCount':4},'PATCH')
                    if first is None:first={'manga':manga['id'],'chapter':chapters[0]['id']}
            (root/'preview.json').write_text(json.dumps(first))
            output=Path(tempfile.mkdtemp(prefix='sumidoku-native-desktop-renders-'))
            subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
            arguments=['/usr/bin/open','-n','-W',str(app),'--args',str(root),str(output)]
            if os.environ.get('SUMIDOKU_TEST_SIDEBAR_ONLY')=='1': arguments.append('--sidebar-only')
            if os.environ.get('SUMIDOKU_TEST_NO_CAPTURE')=='1': arguments.append('--no-capture')
            subprocess.run(arguments,env=env,check=True,timeout=150)
            result=json.loads((root/'render-result.json').read_text())
            if not result['success']:raise RuntimeError(json.dumps(result))
            (output/'verification.json').write_text(json.dumps({'version':client_version,'build':client_build,**result},indent=2)+'\n')
            print('Native verification:',json.dumps(result,sort_keys=True))
            print('Native fixture renders:' if result.get('nativeWindowCaptures') else 'Native behavior checks passed; visual capture explicitly NOT performed:',output)
        finally:
            server.send_signal(signal.SIGINT)
            try:server.wait(timeout=20)
            except subprocess.TimeoutExpired:server.kill();server.wait()
