#!/usr/bin/env python3
"""Publish only independently qualified, publisher-authenticated desktop artifacts.

Invoked by protected desktop-only CI. No application installation, Cargo version,
server/Docker release, private user data or repository code execution is involved.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from urllib.parse import urlsplit

REPO='TTokomon/SumidokuApp'
REQUIRED={'native-community-roundtrip','package-security','update-policy','packaging','frontend','required-ci'}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def run(*args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def verify(root,tool,key):
    if len(base64.b64decode(key,validate=True))!=32:raise ValueError('Missing publisher trust root')
    root=root.resolve();catalog=root/'desktop-releases.json'
    run(str(tool),'catalog',str(catalog),str(catalog)+'.sig',key)
    proof=root/'release-qualification.json'
    run(str(tool),'signed-file',str(proof),str(proof)+'.sig',key)
    qualification=json.loads(proof.read_text());plan=json.loads((root/'release-plan.json').read_text());data=json.loads(catalog.read_text())
    if qualification.get('format')!=1 or qualification.get('status')!='passed' or not REQUIRED.issubset(set(qualification.get('checks',[]))):raise ValueError('Incomplete release-critical qualification')
    if qualification.get('catalogSha256')!=sha(catalog) or qualification.get('appcastSha256')!=sha(root/'appcast.xml') or qualification.get('inventorySha256')!=sha(root/'SHA256SUMS'):raise ValueError('Qualification is not for these exact artifacts')
    if plan.get('draft') is not True or plan.get('published') is not False:raise ValueError('Expected an unpublished release plan')
    selected=[e for e in data['releases'] if 'desktop-v'+e['version']==plan.get('tag')]
    if len(selected)!=1:raise ValueError('Ambiguous release plan')
    entry=selected[0]
    if qualification.get('version')!=entry['version'] or qualification.get('build')!=entry['build'] or qualification.get('archiveSha256')!=entry['sha256']:raise ValueError('Qualification does not select this exact version/build/archive')
    if qualification.get('sourceRevision')!=entry['sourceRevision']:raise ValueError('Qualification provenance mismatch')
    if plan.get('prerelease')!=(entry['channel']=='beta'):raise ValueError('Release channel mismatch')
    archive=root/Path(urlsplit(entry['url']).path).name
    if archive.parent!=root or archive.is_symlink() or sha(archive)!=entry['sha256'] or archive.stat().st_size!=entry['length']:raise ValueError('Release archive mismatch')
    run(str(tool),'archive',str(archive),str(catalog),str(catalog)+'.sig',key,entry['version'])
    inventory={}
    for line in (root/'SHA256SUMS').read_text().splitlines():
        digest,name=line.split('  ',1)
        if name in inventory or Path(name).name!=name or not re.fullmatch('[a-f0-9]{64}',digest):raise ValueError('Unsafe checksum inventory')
        p=root/name
        if p.is_symlink() or sha(p)!=digest:raise ValueError('Checksum inventory mismatch')
        inventory[name]=digest
    for name in [archive.name,'desktop-releases.json','desktop-releases.json.sig','appcast.xml']:
        if name not in inventory:raise ValueError('Incomplete checksum inventory')
    return plan,entry,archive

def publish(root,tool,key):
    plan,entry,archive=verify(root,tool,key)
    # Retain every already published, authenticated entry, including Stable.
    with tempfile.TemporaryDirectory(prefix='sumidoku-prior-feed-') as directory:
        prior=Path(directory)/'desktop-releases.json'
        available=subprocess.run(['gh','release','view','desktop-updates','--repo',REPO],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if available.returncode!=0 and entry['channel']=='beta':raise ValueError('Publish and verify the Stable feed before publishing Beta')
        if available.returncode==0:
            run('gh','release','download','desktop-updates','--repo',REPO,'--pattern','desktop-releases.json*','--dir',directory)
            run(str(tool),'catalog',str(prior),str(prior)+'.sig',key)
            old=json.loads(prior.read_text())['releases']
            if entry['channel']=='beta' and not any(e['channel']=='stable' for e in old):raise ValueError('A published authenticated Stable baseline is required before Beta')
            new=json.loads((root/'desktop-releases.json').read_text())['releases']
            if any(entry not in new for entry in old):raise ValueError('Publication would remove or alter an existing release')
    # CI alone creates desktop tags/releases, under an approval-protected environment.
    tag=plan['tag']
    existing=subprocess.run(['gh','release','view',tag,'--repo',REPO,'--json','isDraft,targetCommitish,tagName'],capture_output=True,text=True)
    if existing.returncode==0:
        value=json.loads(existing.stdout)
        if not value.get('isDraft') or value.get('tagName')!=tag or value.get('targetCommitish')!=entry['sourceRevision']:
            raise ValueError('Published releases are immutable; a staged draft must target the qualified source')
    else:
        run('gh','release','create',tag,str(archive),str(root/'SHA256SUMS'),str(root/'release-qualification.json'),str(root/'release-qualification.json.sig'),'--repo',REPO,'--target',entry['sourceRevision'],'--draft','--title','Sumidoku Desktop '+entry['version'],'--notes-file',str(root/'RELEASE_NOTES.md'),*(['--prerelease'] if plan['prerelease'] else []))
    run('gh','release','edit',tag,'--repo',REPO,'--draft=false','--latest=false' if plan['prerelease'] else '--latest=true')
    # Feed replacement is deliberately separate and fails closed during the short
    # catalog/signature replacement interval. Keep all authenticated Stable entries.
    feed='desktop-updates'
    result=subprocess.run(['gh','release','view',feed,'--repo',REPO],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if result.returncode!=0:
        run('gh','release','create',feed,'--repo',REPO,'--target',entry['sourceRevision'],'--title','Desktop signed update feeds','--notes','Publisher-authenticated Stable/Beta desktop update catalog.','--latest=false')
    run('gh','release','upload',feed,str(root/'appcast.xml'),str(root/'desktop-releases.json'),str(root/'desktop-releases.json.sig'),'--repo',REPO,'--clobber')

def stage_local(root,tool,key):
    """Upload already signed public artifacts to a CI-created draft; never create or publish."""
    plan,entry,archive=verify(root,tool,key)
    value=json.loads(subprocess.check_output(['gh','release','view',plan['tag'],'--repo',REPO,'--json','isDraft,targetCommitish,tagName']))
    if not value.get('isDraft') or value.get('targetCommitish')!=entry['sourceRevision'] or value.get('tagName')!=plan['tag']:
        raise ValueError('Local staging requires the matching unpublished CI-created draft')
    names=['SHA256SUMS','appcast.xml','desktop-releases.json','desktop-releases.json.sig','RELEASE_NOTES.md','release-plan.json','release-qualification.json','release-qualification.json.sig']
    run('gh','release','upload',plan['tag'],str(archive),*[str(root/name) for name in names],'--repo',REPO)
    print('Signed public artifacts uploaded to an existing draft; no private key exported and nothing published')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('artifacts',type=Path);parser.add_argument('--trust-tool',required=True,type=Path);parser.add_argument('--verify-only',action='store_true');parser.add_argument('--stage-local',action='store_true');args=parser.parse_args()
    key=os.environ['SUMIDOKU_UPDATE_PUBLIC_KEY']
    (verify if args.verify_only else stage_local if args.stage_local else publish)(args.artifacts,args.trust_tool,key)
