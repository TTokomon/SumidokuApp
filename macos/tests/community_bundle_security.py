#!/usr/bin/env python3
"""Publisher-seal rejection tests using an actual native bundle, not fixture executables."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

def main(app,tool,key):
    def verify(target,public=key):
        return subprocess.run([str(tool),'bundle',str(target),public],capture_output=True,text=True).returncode==0
    assert verify(app),'Valid real native publisher-sealed bundle must pass'
    assert not verify(app,base64.b64encode(bytes(32)).decode()),'Wrong public key accepted'
    assertions=2
    with tempfile.TemporaryDirectory(prefix='sumidoku-community-seal-') as temporary:
        copy=Path(temporary)/'Sumidoku.app';shutil.copytree(app,copy,symlinks=True)
        # Verify through macOS's alternative temporary-root spelling.
        alias=Path(str(copy).replace('/private/var/','/var/',1).replace('/private/tmp/','/tmp/',1))
        assert verify(alias),'Equivalent filesystem alias changed the signed inventory';assertions+=1
        cases=[('Contents/MacOS/SumidokuUpdateHelper',b'changed helper'),('Contents/Resources/sumidoku-server',b'changed server'),('Contents/Info.plist',b'changed trust flags'),('Contents/Resources/community-seal.json',b'changed seal')]
        for relative,content in cases:
            path=copy/relative;original=path.read_bytes();path.write_bytes(content)
            assert not verify(copy),relative+' tampering accepted';assertions+=1;path.write_bytes(original)
        path=copy/'Contents/MacOS/Sumidoku';original=path.read_bytes();changed=bytearray(original);changed[4096]^=1;path.write_bytes(changed)
        subprocess.run(['codesign','--force','--sign','-',str(copy)],check=True,capture_output=True)
        assert not verify(copy),'Re-signing altered native code bypassed publisher seal';assertions+=1;path.write_bytes(original)
        # A local attacker may recreate ad-hoc signatures. That never grants
        # publisher identity for extra resources, permissions or hidden payloads.
        payload=copy/'Contents/Resources/unexpected.dylib';payload.write_bytes(b'untrusted code')
        subprocess.run(['codesign','--force','--sign','-',str(copy)],check=True,capture_output=True)
        assert not verify(copy),'Added resource plus fresh ad-hoc signature accepted';assertions+=1;payload.unlink()
        payload=copy/'Contents/_CodeSignature/unexpected.dylib';payload.write_bytes(b'hidden code')
        assert not verify(copy),'Unexpected signature-directory payload accepted';assertions+=1;payload.unlink()
        payload=copy/'Contents/Resources/escaped';payload.symlink_to('/etc/passwd')
        assert not verify(copy),'Escaping symlink accepted';assertions+=1;payload.unlink()
    print(f'PASS: {assertions} real native bundle publisher-seal acceptance/rejection checks')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('app',type=Path);parser.add_argument('--trust-tool',required=True,type=Path);parser.add_argument('--public-key',required=True);args=parser.parse_args();main(args.app.resolve(),args.trust_tool.resolve(),args.public_key)
