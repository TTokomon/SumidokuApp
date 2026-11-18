#!/usr/bin/env python3
"""Local GET-only preparation of short-lived draft asset read capabilities.

No signing credential is read, no release is changed, and the GitHub account
token stays in this process and its authenticated API requests. Never log URLs.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import common


def prepare(version,output):
    tag='desktop-v'+version;entry=common.selected(version)
    release=common.maybe_release(tag)
    if not release or release['draft'] is not True or release['tag_name']!=tag or release['target_commitish']!=entry['sourceRevision']:raise ValueError('Expected the matching unpublished draft')
    assets={a['name']:a for a in release['assets']}
    if len(assets)!=len(release['assets']) or set(assets)!=set(common.filenames(version)):raise ValueError('Unexpected draft assets')
    token=subprocess.check_output(['gh','auth','token','--hostname','github.com'],text=True).strip()
    created=int(time.time());value={'format':1,'repository':common.REPO,'tag':tag,'sourceRevision':entry['sourceRevision'],'draft':True,'releaseId':release['id'],'created':created,'expires':created+1200,'assets':{}}
    opener=urllib.request.build_opener(common.NoRedirect())
    for name,asset in assets.items():
        if type(asset['id']) is not int or not asset.get('digest','').startswith('sha256:'):raise ValueError('Missing GitHub asset identity/digest')
        request=urllib.request.Request(f'https://api.github.com/repos/{common.REPO}/releases/assets/{asset["id"]}',headers={'Authorization':'Bearer '+token,'Accept':'application/octet-stream','User-Agent':'Sumidoku-release-transport'})
        try:
            with opener.open(request,timeout=30):raise ValueError('Expected an asset-scoped redirect')
        except urllib.error.HTTPError as error:
            if error.code!=302:raise ValueError('Draft download capability unavailable') from None
            url=error.headers.get('Location','');error.close()
        value['assets'][name]={'url':url,'size':asset['size'],'sha256':asset['digest'][7:]}
    raw=json.dumps(value);common.draft_transport(raw,version,tag)
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as stream:stream.write(raw)
    print('Prepared nine short-lived asset-read capabilities; no signing key or repository token exported.')


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--version',required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    prepare(args.version,args.output)
