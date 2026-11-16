#!/usr/bin/env python3
"""Prepare unpublished, signed desktop artifacts. Never creates tags or releases."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)

def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def release_version(value):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-beta\.[1-9][0-9]*)?', value):
        raise ValueError('Expected a desktop stable or numbered beta version.')
    return value

def prepare(app, output, sparkle, trust_tool, previous=None):
    app, output, sparkle = Path(app), Path(output), Path(sparkle)
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    version = release_version(info.get('SumidokuReleaseVersion') or info['CFBundleShortVersionString'])
    if '-beta.' in version and not previous:
        raise ValueError('Beta requires an authenticated published Stable catalog; no baseline is fabricated.')
    team = info.get('SumidokuReleaseTeam', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team) or info.get('SumidokuDevelopmentBuild', True):
        raise ValueError('Developer ID release configuration is required; development builds cannot be distributed.')
    if len(base64.b64decode(info.get('SUPublicEDKey',''),validate=True)) != 32:
        raise ValueError('A pinned Ed25519 public key is required.')
    from urllib.parse import urlsplit
    feed, catalog = map(urlsplit, [info.get('SUFeedURL',''),info.get('SumidokuReleaseCatalogURL','')])
    if any(u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment for u in [feed,catalog]) or feed.hostname != catalog.hostname:
        raise ValueError('Appcast and catalog must use the same trusted HTTPS origin.')
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    requirement = f'anchor apple generic and identifier "app.sumidoku.desktop" and certificate leaf[subject.OU] = "{team}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    subprocess.run(['codesign','--verify','--strict','-R',requirement,str(app)],check=True)
    subprocess.run(['spctl','--assess','--type','execute',str(app)],check=True)
    subprocess.run(['xcrun','stapler','validate',str(app)],check=True)
    for relative in ['Contents/MacOS/Sumidoku','Contents/Resources/sumidoku-server','Contents/MacOS/SumidokuUpdateHelper']:
        executable=app/relative
        if executable.exists():subprocess.run(['lipo','-verify_arch','arm64',str(executable)],check=True)
    server = app/'Contents/Resources/sumidoku-server'
    manifest = json.loads((app/'Contents/Resources/server-build.json').read_text())
    if manifest['sha256'] != digest(server) or manifest['variant'] != 'fork':
        raise ValueError('App/server manifest mismatch.')
    if '-beta.' in version:
        proof=json.loads((app/'Contents/Resources/client-build.json').read_text())
        if proof.get('dirty') is not False or proof.get('sourceRevision') != manifest['sourceRevision']:
            raise ValueError('Beta requires clean, exact-source client and server provenance from the same reviewed commit.')
    if '-beta.' not in version:
        qualified=json.loads(Path(__file__).with_name('stable-baselines.json').read_text())['qualified']
        expected={'version':version,'build':int(info['CFBundleVersion']),'sourceRevision':manifest['sourceRevision'],
                  'clientSha256':digest(app/'Contents/MacOS/Sumidoku'),'serverSha256':digest(server),
                  'schema':manifest['databaseSchemaVersion']}
        if expected not in qualified:
            raise ValueError('Stable artifact provenance is not qualified. Review and pin the exact audited artifact before packaging.')
    if output.exists():
        raise ValueError('Output exists; previous release artifacts are preserved.')
    output.mkdir(parents=True,mode=0o700)
    archive=output/f'Sumidoku-Desktop-{version}-macOS-arm64.zip'
    subprocess.run(['ditto','-c','-k','--norsrc','--noextattr','--keepParent',str(app),str(archive)],check=True)
    # A CI secret travels on stdin only. Locally Sparkle reads its Keychain account.
    secret=os.environ.pop('SUMIDOKU_SPARKLE_PRIVATE_KEY',None)
    def sign(path, verify=None):
        args=[str(sparkle/'bin/sign_update')]
        args += ['--ed-key-file','-'] if secret else ['--account','app.sumidoku.desktop.release']
        if verify is not None:
            args += ['--verify',str(path)] + ([verify] if verify else [])
        else:
            args += ['-p',str(path)]
        return subprocess.run(args,input=secret+'\n' if secret else None,capture_output=True,text=True,check=True).stdout.strip()
    signature=sign(archive)
    sign(archive,signature)
    entry={'version':version,'build':int(info['CFBundleVersion']),'channel':'beta' if '-beta.' in version else 'stable',
           'url':f'https://github.com/TTokomon/SumidokuApp/releases/download/desktop-v{version}/{archive.name}',
           'length':archive.stat().st_size,'signature':signature,'sha256':digest(archive),
           'clientSha256':digest(app/'Contents/MacOS/Sumidoku'),'serverSha256':digest(server),
           'sourceRevision':manifest['sourceRevision'],'schema':manifest['databaseSchemaVersion']}
    entries=[]
    if previous:
        previous=Path(previous)
        subprocess.run([str(trust_tool),'catalog',str(previous),str(previous)+'.sig',info['SUPublicEDKey']],check=True)
        entries=json.loads(previous.read_text())['releases']
    if any(e['version']==version for e in entries):
        raise ValueError('Existing version is immutable; choose a new version/build.')
    if entry['channel']=='beta' and not any(e['channel']=='stable' for e in entries):
        raise ValueError('A verified signed Stable catalog is required before preparing Beta.')
    entries.append(entry)
    path=output/'desktop-releases.json'
    path.write_text(json.dumps({'format':1,'releases':entries},sort_keys=True,separators=(',',':'))+'\n')
    Path(str(path)+'.sig').write_text(sign(path)+'\n')
    subprocess.run([str(trust_tool),'catalog',str(path),str(path)+'.sig',info['SUPublicEDKey']],check=True)
    rss=ET.Element('rss',{'version':'2.0'});channel=ET.SubElement(rss,'channel');ET.SubElement(channel,'title').text='Sumidoku Desktop'
    for e in entries:
        item=ET.SubElement(channel,'item');ET.SubElement(item,'title').text='Sumidoku Desktop '+e['version']
        ET.SubElement(item,f'{{{SPARKLE}}}version').text=str(e['build'])
        ET.SubElement(item,f'{{{SPARKLE}}}shortVersionString').text=e['version']
        ET.SubElement(item,f'{{{SPARKLE}}}minimumSystemVersion').text='13.0'
        if e['channel']=='beta':ET.SubElement(item,f'{{{SPARKLE}}}channel').text='beta'
        ET.SubElement(item,'description').text='Paired application/server update. Restore Stable preserves current data and requires a compatible schema.'
        ET.SubElement(item,'enclosure',{'url':e['url'],'length':str(e['length']),'type':'application/octet-stream',f'{{{SPARKLE}}}edSignature':e['signature']})
    feed_path=output/'appcast.xml';ET.ElementTree(rss).write(feed_path,encoding='utf-8',xml_declaration=True)
    sign(feed_path);sign(feed_path,'')
    (output/'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in sorted(output.iterdir()) if p.is_file()))
    (output/'release-plan.json').write_text(json.dumps({'tag':'desktop-v'+version,'prerelease':entry['channel']=='beta','draft':True,'published':False,'sourceRevision':entry['sourceRevision'],'baselineRequired':entry['channel']=='beta'},indent=2)+'\n')
    (output/'RELEASE_NOTES.md').write_text(f'# Sumidoku Desktop {version}\n\nUnpublished candidate from `{entry["sourceRevision"]}`. Native navigation and grouped settings; paired app/server update and explicit Restore Stable with current-data compatibility checks. No database rollback or automatic chapter downloads. A one-time approved updater-capable Stable installation may be required.\n\nPublishing requires successful signed Stable-to-Beta-to-Stable testing and explicit approval.\n')
    return entry

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('app',type=Path);parser.add_argument('output',type=Path);parser.add_argument('--sparkle',type=Path,required=True);parser.add_argument('--trust-tool',type=Path,required=True);parser.add_argument('--previous-catalog',type=Path)
    args=parser.parse_args();prepare(args.app,args.output,args.sparkle,args.trust_tool,args.previous_catalog)
