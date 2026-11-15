#!/usr/bin/env python3
"""Cache a checksum-pinned official Sparkle distribution; never access signing keys."""
from pathlib import Path
import fcntl
import hashlib
import json
import os
import shutil
import tarfile
import tempfile
import urllib.request
import uuid
VERSION='2.10.1'
SHA256='1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
CACHE=Path('/private/tmp/sumidoku-sparkle-'+VERSION)
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def safe(path):
    return not path.is_symlink() and path.stat().st_uid==os.getuid() and not path.stat().st_mode & 0o022

def valid():
    if not CACHE.exists():return False
    if not safe(CACHE):raise RuntimeError('Sparkle cache ownership/permissions need review; nothing replaced.')
    try:
        receipt=json.loads((CACHE/'build-cache-receipt.json').read_text())
        return receipt['archive']==SHA256 and all((CACHE/name).resolve().is_relative_to(CACHE) and digest(CACHE/name)==value for name,value in receipt['files'].items())
    except (OSError,KeyError,ValueError):return False

lock=os.open(str(CACHE)+'.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
with os.fdopen(lock,'r+') as handle:
    if os.fstat(handle.fileno()).st_uid!=os.getuid():raise RuntimeError('Foreign build cache lock rejected.')
    fcntl.flock(handle,fcntl.LOCK_EX)
    if not valid():
        with tempfile.TemporaryDirectory(prefix='sumidoku-sparkle-download-') as directory:
            root=Path(directory);archive=root/'Sparkle.tar.xz';stage=root/'unpacked';stage.mkdir(mode=0o700)
            request=urllib.request.Request(f'https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-{VERSION}.tar.xz',headers={'User-Agent':'Sumidoku-build'})
            with urllib.request.urlopen(request,timeout=60) as response,archive.open('wb') as output:shutil.copyfileobj(response,output)
            if digest(archive)!=SHA256:raise RuntimeError('Sparkle checksum mismatch; no framework installed.')
            with tarfile.open(archive) as package:package.extractall(stage,filter='data')
            files={str(path.relative_to(stage)):digest(path) for path in stage.rglob('*') if path.is_file() and not path.is_symlink()}
            (stage/'build-cache-receipt.json').write_text(json.dumps({'archive':SHA256,'files':files})+'\n')
            (stage/'build-cache-receipt.json').chmod(0o600)
            if CACHE.exists():os.replace(CACHE,CACHE.with_name(CACHE.name+'-superseded-'+uuid.uuid4().hex))
            os.replace(stage,CACHE)
    if not valid():raise RuntimeError('Sparkle cache verification failed.')
print(CACHE)
