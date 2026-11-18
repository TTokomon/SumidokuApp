"""Main-owned release transport and strict file handling. Never imports product code."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time
import urllib.request
from urllib.parse import urlsplit
import zipfile

REPO='TTokomon/SumidokuApp'
META={'SHA256SUMS':65536,'appcast.xml':2_000_000,'desktop-releases.json':2_000_000,'desktop-releases.json.sig':256,'RELEASE_NOTES.md':100000,'release-plan.json':65536,'release-qualification.json':2_000_000,'release-qualification.json.sig':256}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def policy():
    value=json.loads(Path(__file__).with_name('policy.json').read_text())
    if value['format']!=1 or value['repository']!=REPO:raise ValueError('Untrusted release policy')
    return value

def selected(version):
    value=policy()['approvedReleases'].get(version)
    if value is None:raise ValueError('Version is not in the reviewed main-owned release policy')
    return value

def filenames(version):
    selected(version)
    return {**META,'Sumidoku-Desktop-'+version+'-macOS-arm64.zip':536_870_912}

def file_set(root,version):
    root=root.resolve();expected=filenames(version)
    if {p.name for p in root.iterdir()}!=set(expected):raise ValueError('Unexpected or missing artifact files')
    for name,limit in expected.items():
        p=root/name;mode=p.lstat().st_mode
        if not stat.S_ISREG(mode) or p.stat().st_size>limit or p.stat().st_size==0:raise ValueError('Unsafe or oversized artifact file')
    return {name:sha(root/name) for name in sorted(expected)}

def gh_json(*args):return json.loads(subprocess.check_output(['gh',*args],text=True))
def maybe_release(tag):
    # Distinguish not-found from authentication/rate-limit/transport errors.
    result=subprocess.run(['gh','api',f'repos/{REPO}/releases/tags/{tag}'],capture_output=True,text=True)
    if result.returncode:
        if '(HTTP 404)' in result.stderr:
            # Unpublished drafts may be invisible through the tag endpoint.
            # Search exact tags, with bounded pagination and no error-as-absence.
            for page in range(1,21):
                releases=gh_json('api',f'repos/{REPO}/releases?per_page=100&page={page}')
                if not isinstance(releases,list):raise ValueError('Invalid release list')
                matches=[r for r in releases if r.get('tag_name')==tag]
                if len(matches)>1:raise ValueError('Ambiguous release tag')
                if matches:return matches[0]
                if len(releases)<100:return None
            raise ValueError('Release lookup pagination limit exceeded')
        raise RuntimeError('GitHub release lookup failed; nothing may be published')
    return json.loads(result.stdout)

def download_stream(endpoint,destination,limit,expected=None):
    # Actions returns a ZIP redirect from its JSON API. Release assets need
    # octet-stream to select binary content instead of asset metadata.
    accept = "application/octet-stream"
    if re.fullmatch(rf"repos/{re.escape(REPO)}/actions/artifacts/[0-9]+/zip", endpoint):
        accept = "application/vnd.github+json"
    process = subprocess.Popen(
        ["gh", "api", endpoint, "-H", f"Accept: {accept}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    count=0
    try:
        with destination.open('xb') as stream:
            while True:
                data=process.stdout.read(65536)
                if not data:break
                count+=len(data)
                if count>limit or (expected is not None and count>expected):raise ValueError('Download exceeded its size bound')
                stream.write(data)
        if process.wait()!=0 or (expected is not None and count!=expected):raise ValueError('Incomplete artifact download')
    finally:
        if process.poll() is None:process.kill()
        process.wait();process.stdout.close()

def download_asset(asset,destination,limit):
    if type(asset.get('id')) is not int or type(asset.get('size')) is not int or not 0<asset['size']<=limit:raise ValueError('Invalid or oversized release asset')
    download_stream(f'repos/{REPO}/releases/assets/{asset["id"]}',destination,limit,asset['size'])
    digest=asset.get('digest')
    if digest and digest!='sha256:'+sha(destination):raise ValueError('GitHub asset digest mismatch')

def draft_transport(raw,version,tag):
    # Maintainer-provided capabilities can only read the specific public-package
    # bytes. They never confer repository write or account access.
    if not raw or len(raw)>64000:raise ValueError('Missing or oversized draft transport')
    value=json.loads(raw);now=time.time()
    if set(value)!={'format','repository','tag','sourceRevision','draft','created','expires','assets'} or value['format']!=1 or value['repository']!=REPO or value['tag']!=tag or tag!='desktop-v'+version or value['sourceRevision']!=selected(version)['sourceRevision'] or value['draft'] is not True:raise ValueError('Draft transport identity mismatch')
    if type(value['created']) is not int or type(value['expires']) is not int or value['expires']!=value['created']+1200 or not value['created']-30<=now<=value['expires']:raise ValueError('Expired or invalid draft transport')
    if type(value['assets']) is not dict or set(value['assets'])!=set(filenames(version)):raise ValueError('Unexpected draft transport files')
    for name,asset in value['assets'].items():
        if set(asset)!={'url','size','sha256'} or type(asset['size']) is not int or not 0<asset['size']<=filenames(version)[name] or not re.fullmatch('[a-f0-9]{64}',asset['sha256']):raise ValueError('Invalid draft transport asset')
        url=asset['url']
        if not isinstance(url,str) or len(url)>16000 or not url.isascii() or any(c in url for c in '\r\n\0'):raise ValueError('Unsafe draft asset URL')
        u=urlsplit(url)
        if u.scheme!='https' or u.hostname!='release-assets.githubusercontent.com' or u.port not in [None,443] or u.username or u.password or u.fragment or not u.query:raise ValueError('Unsafe draft asset URL')
    archive='Sumidoku-Desktop-'+version+'-macOS-arm64.zip'
    if value['assets'][archive]['sha256']!=selected(version)['sha256'] or value['assets'][archive]['size']!=selected(version)['length']:raise ValueError('Draft transport archive is not approved')
    return value['assets']

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None

def download_capability(asset,destination):
    try:
        request=urllib.request.Request(asset['url'],headers={'User-Agent':'Sumidoku-release-verifier'})
        with urllib.request.build_opener(NoRedirect()).open(request,timeout=60) as source,destination.open('xb') as target:
            count=0
            while data:=source.read(65536):
                count+=len(data)
                if count>asset['size']:raise ValueError('Download exceeded its size bound')
                target.write(data)
        if count!=asset['size'] or sha(destination)!=asset['sha256']:raise ValueError('Draft asset size or digest mismatch')
    except Exception:
        # Never include bearer URLs in logs, including HTTP exception messages.
        raise ValueError('Draft asset transport failed; URL withheld') from None

def unpack_artifact(archive,root):
    # Actions' artifact transport is a ZIP too: never extract arbitrary paths.
    allowed={name:limit for v in policy()['approvedReleases'] for name,limit in filenames(v).items()}
    with zipfile.ZipFile(archive) as package:
        seen=set()
        for item in package.infolist():
            mode=item.external_attr>>16
            if item.filename not in allowed or item.filename in seen or item.is_dir() or stat.S_ISLNK(mode) or (mode and stat.S_IFMT(mode) not in [0,stat.S_IFREG]) or not 0<item.file_size<=allowed[item.filename]:raise ValueError('Unsafe workflow artifact ZIP')
            seen.add(item.filename)
            with package.open(item) as source,(root/item.filename).open('xb') as target:
                count=0
                while data:=source.read(65536):
                    count+=len(data)
                    if count>allowed[item.filename]:raise ValueError('Expanded artifact too large')
                    target.write(data)

def require_main():
    expected=REPO+'/.github/workflows/desktop-publish.yml@refs/heads/main'
    if os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('GITHUB_REPOSITORY')!=REPO or os.environ.get('GITHUB_REF')!='refs/heads/main' or os.environ.get('GITHUB_WORKFLOW_REF')!=expected:raise ValueError('Publication is restricted to the approved main workflow')
