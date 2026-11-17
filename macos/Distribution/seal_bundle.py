#!/usr/bin/env python3
"""Seal a community bundle with the publisher key, then finalize its ad-hoc resource envelope."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess


def seal(app, sparkle, tool):
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if info.get('SumidokuDistributionMode')!='community':
        raise ValueError('Bundle sealing requires explicit community distribution mode')
    subprocess.run([str(tool),'seal',str(app)],check=True)
    manifest=app/'Contents/Resources/community-seal.json'
    secret=os.environ.pop('SUMIDOKU_SPARKLE_PRIVATE_KEY',None)
    args=[str(sparkle/'bin/sign_update')]
    args+=['--ed-key-file','-'] if secret else ['--account',os.environ.get('SUMIDOKU_SPARKLE_KEY_ACCOUNT','app.sumidoku.desktop.community.release')]
    result=subprocess.run(args+['-p',str(manifest)],input=secret+'\n' if secret else None,capture_output=True,text=True)
    if result.returncode:raise RuntimeError('Publisher sealing failed; check the protected signing key configuration')
    (app/'Contents/Resources/community-seal.sig').write_text(result.stdout.strip()+'\n')
    subprocess.run(['codesign','--force','--sign','-','--identifier','app.sumidoku.desktop',str(app)],check=True)
    subprocess.run([str(tool),'bundle',str(app),info['SUPublicEDKey']],check=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('app',type=Path);parser.add_argument('--sparkle',required=True,type=Path);parser.add_argument('--trust-tool',required=True,type=Path)
    args=parser.parse_args();seal(args.app,args.sparkle,args.trust_tool)
