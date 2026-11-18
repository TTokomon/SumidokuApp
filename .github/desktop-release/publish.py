#!/usr/bin/env python3
"""Main-owned write phase. Consumes data from this run's read-only verifier.

No product checkout, PR module, compiler, app execution, installer or signing key.
"""
import argparse
import json
import os
import re
import stat
import tempfile
import zipfile
from pathlib import Path
import subprocess
import common
import validate

FEED_FILES=('appcast.xml','desktop-releases.json','desktop-releases.json.sig')


def read_receipt(path):
    if not path.is_file() or path.is_symlink() or not 0<path.stat().st_size<=common.RECEIPT_LIMIT:
        raise ValueError('Missing or unsafe verification receipt')
    value=json.loads(path.read_bytes())
    if not isinstance(value,dict) or set(value)!={'format','repository','onlineChecks','toolingCommit','policySha256','run','version','tag','sourceRevision','prerelease','releaseId','files','sizes','priorFeed'}:
        raise ValueError('Untrusted validation receipt')
    if value['format']!=2 or value['repository']!=common.REPO or value['onlineChecks'] is not True or value['toolingCommit']!=common.policy()['toolingCommit'] or value['policySha256']!=common.policy_digest():
        raise ValueError('Untrusted validation receipt')
    run=common.run_identity()
    if not re.fullmatch('[1-9][0-9]*',run['id'] or '') or not re.fullmatch('[a-f0-9]{40}',run['head'] or '') or run['workflow']!=common.REPO+'/.github/workflows/desktop-publish.yml@refs/heads/main' or value['run']!=run:
        raise ValueError('Receipt does not belong to this workflow run and commit')
    if value['version']!=os.environ.get('DESKTOP_VERSION'):
        raise ValueError('Receipt version does not match the workflow input')
    entry=common.selected(value['version'])
    if value['tag']!='desktop-v'+entry['version'] or value['sourceRevision']!=entry['sourceRevision'] or value['prerelease'] is not (entry['channel']=='beta'):
        raise ValueError('Validation plan does not match approved release')
    if value['releaseId'] is not None and (type(value['releaseId']) is not int or value['releaseId']<=0):
        raise ValueError('Invalid draft release identity')
    limits=common.filenames(value['version'])
    for field in ('files','sizes'):
        if type(value[field]) is not dict or set(value[field])!=set(limits):
            raise ValueError('Unexpected files in validation receipt')
    for name,limit in limits.items():
        if not is_digest(value['files'][name]) or type(value['sizes'][name]) is not int or not 0<value['sizes'][name]<=limit:
            raise ValueError('Invalid file digest or size in receipt')
    archive='Sumidoku-Desktop-'+value['version']+'-macOS-arm64.zip'
    if value['files'][archive]!=entry['sha256'] or value['sizes'][archive]!=entry['length']:
        raise ValueError('Archive is not the reviewed approved release')
    prior=value['priorFeed']
    if prior is not None and (type(prior) is not dict or set(prior)!=set(FEED_FILES) or not all(is_digest(v) for v in prior.values())):
        raise ValueError('Unsafe prior-feed receipt')
    return value


def is_digest(value):
    return isinstance(value,str) and re.fullmatch('[a-f0-9]{64}',value) is not None


def fetch_receipt(identifier,destination):
    common.require_main()
    if not re.fullmatch('[1-9][0-9]*',identifier):
        raise ValueError('Missing verification artifact identity')
    endpoint=f'repos/{common.REPO}/actions/artifacts/{identifier}'
    metadata=common.gh_json('api',endpoint)
    run=metadata['workflow_run']
    if str(run['id'])!=common.run_identity()['id'] or run['head_sha']!=common.run_identity()['head'] or metadata['name']!=common.RECEIPT_ARTIFACT or metadata['expired'] is not False:
        raise ValueError('Verification artifact is not from this workflow run')
    with tempfile.TemporaryDirectory(prefix='desktop-receipt-') as directory:
        package=Path(directory)/'receipt.zip'
        common.download_stream(endpoint+'/zip',package,2*common.RECEIPT_LIMIT)
        with zipfile.ZipFile(package) as archive:
            items=archive.infolist()
            if len(items)!=1:
                raise ValueError('Expected a receipt-only workflow artifact')
            item=items[0]
            mode=stat.S_IFMT(item.external_attr>>16)
            if item.filename!=common.RECEIPT_NAME or item.is_dir() or mode not in (0,stat.S_IFREG) or not 0<item.file_size<=common.RECEIPT_LIMIT:
                raise ValueError('Unsafe verification receipt artifact')
            with archive.open(item) as source:
                payload=source.read(common.RECEIPT_LIMIT+1)
            if len(payload)!=item.file_size:
                raise ValueError('Invalid receipt size')
            with destination.open('xb') as target:
                target.write(payload)
    read_receipt(destination)


def authenticate_downloads(plan,root,prepared):
    release,feed=inspect_remote(plan)
    remote=assets(release)
    limits=common.filenames(plan['version'])
    for name,limit in limits.items():
        common.download_asset(remote[name],root/name,limit)
    if common.file_set(root,plan['version'])!=plan['files'] or any((root/name).stat().st_size!=size for name,size in plan['sizes'].items()):
        raise ValueError('Draft bytes do not match the authenticated receipt')
    # Re-authenticate signed archive, provenance, catalog, qualification, notices
    # and signed inventory using the reviewed native verifier compiled before
    # this step. A fabricated receipt cannot authorize unsigned release bytes.
    credentials={name:os.environ.pop(name) for name in ('GH_TOKEN','GITHUB_TOKEN') if name in os.environ}
    try:
        validate.verify(root,plan['version'],prepared/'reviewed-source',prepared/'TrustTool')
    finally:
        os.environ.update(credentials)
    # When the original baseline is still intact, authenticate the live catalog
    # again. Interrupted retries may instead see a mix of receipt-pinned old and
    # newly signed bytes, as checked by inspect_remote.
    catalog=json.loads((root/'desktop-releases.json').read_bytes())['releases']
    prior=plan['priorFeed']
    if prior and all(matches(assets(feed).get(name,{}),digest) for name,digest in prior.items()):
        with tempfile.TemporaryDirectory(prefix='desktop-prior-feed-') as directory:
            baseline_dir=Path(directory)
            if validate.prior_feed(prepared/'TrustTool',plan['version'],baseline_dir)!=prior:
                raise ValueError('Public feed changed during protected verification')
            baseline_entries=json.loads((baseline_dir/'desktop-releases.json').read_bytes())['releases']
            if any(item not in catalog for item in baseline_entries):
                raise ValueError('Published release entries must be preserved')
            if plan['prerelease'] and not any(item['channel']=='stable' for item in baseline_entries):
                raise ValueError('Public Stable must precede Beta')
    for item in catalog:
        if item['version']==plan['version']:
            continue
        baseline=common.maybe_release('desktop-v'+item['version'])
        name='Sumidoku-Desktop-'+item['version']+'-macOS-arm64.zip'
        if not baseline or baseline['draft'] or not matches(assets(baseline).get(name,{}),item['sha256'],item['length']):
            raise ValueError('Catalog references a changed or unpublished baseline')


def assets(release):
    items={a['name']:a for a in release['assets']}
    if len(items)!=len(release['assets']):raise ValueError('Duplicate remote assets')
    return items


def matches(asset,digest,size=None):
    return asset.get('digest')=='sha256:'+digest and (size is None or asset.get('size')==size)


def checked_release(plan):
    release=common.maybe_release(plan['tag'])
    if release is None:
        raise ValueError('Stage the complete matching application draft before publication')
    if release['target_commitish']!=plan['sourceRevision'] or release['tag_name']!=plan['tag'] or release['prerelease'] is not plan['prerelease'] or (plan['releaseId'] is not None and release['id']!=plan['releaseId']):
        raise ValueError('Release identity differs from the verified transaction')
    remote=assets(release)
    if set(remote)!=set(plan['files']):
        raise ValueError('Stage the complete matching application draft before publication')
    if any(not matches(asset,plan['files'][name],plan['sizes'][name]) for name,asset in remote.items()):
        raise ValueError('Release asset digest or size changed; immutable')
    return release


def inspect_remote(plan):
    release=checked_release(plan)
    feed=common.maybe_release('desktop-updates');prior=plan['priorFeed']
    recovering=not release['draft']
    if prior and not feed:raise ValueError('Published feed disappeared since validation')
    if feed:
        if feed['tag_name']!='desktop-updates':raise ValueError('Unexpected feed identity')
        remote=assets(feed)
        if set(remote)-set(FEED_FILES):raise ValueError('Unexpected feed assets')
        if prior:
            if feed['draft']:raise ValueError('Existing public feed became a draft')
            for name in FEED_FILES:
                item=remote.get(name)
                if item is None:
                    if not recovering:raise ValueError('Published feed is incomplete')
                elif not matches(item,prior[name]):
                    if not recovering or not matches(item,plan['files'][name],plan['sizes'][name]):raise ValueError('Published feed changed outside this transaction')
        else:
            # Only the first feed's same-source draft may be staged in advance.
            # A public feed is accepted only to finish the identical public app.
            if feed['target_commitish']!=plan['sourceRevision'] or (not feed['draft'] and not recovering):raise ValueError('Published feed changed since validation')
            if any(not matches(item,plan['files'][name],plan['sizes'][name]) for name,item in remote.items()):raise ValueError('Feed contains unauthenticated transaction bytes')
    if plan['prerelease'] and not prior:raise ValueError('Public Stable must precede Beta')
    return release,feed


def write(*args):subprocess.run(['gh',*args],check=True)


def complete_feed(root,plan):
    _,feed=inspect_remote(plan)
    for name in FEED_FILES:
        # Recheck all state before each write, including an interrupted clobber.
        # Only prior authenticated or exact new feed bytes are accepted.
        _,feed=inspect_remote(plan);item=assets(feed).get(name)
        if item and matches(item,plan['files'][name],plan['sizes'][name]):continue
        write('release','upload','desktop-updates',str(root/name),'--repo',common.REPO,*(['--clobber'] if item else []))
        _,feed=inspect_remote(plan);item=assets(feed).get(name)
        if item is None or not matches(item,plan['files'][name],plan['sizes'][name]):raise ValueError('Feed upload digest or size mismatch')
    return feed


def publish(root,plan):
    common.require_main()
    release,feed=inspect_remote(plan);tag=plan['tag']
    notes_file=root/'RELEASE_NOTES.md'
    if common.sha(notes_file)!=plan['files'][notes_file.name]:
        raise ValueError('Release notes do not match the authenticated receipt')
    notes=notes_file.read_bytes().decode('utf-8')
    if release['draft'] and release.get('body')!=notes:
        # Supplying neither --draft=false nor a target preserves the existing
        # draft state. Check the persisted body before changing visibility.
        write('release','edit',tag,'--repo',common.REPO,'--notes-file',str(notes_file))
        release,_=inspect_remote(plan)
        if not release['draft']:
            raise ValueError('Draft visibility changed while setting release notes')
    if release.get('body')!=notes:
        raise ValueError('Release body differs from authenticated notes')
    # Draft creation/local staging is a separate reviewed operation. This writer
    # never uploads application assets, even to a draft: a visibility race cannot
    # make an archive upload touch a public release.
    if feed is None:
        write('release','create','desktop-updates','--repo',common.REPO,'--target',plan['sourceRevision'],'--draft','--title','Desktop signed update feeds','--notes','Publisher-authenticated desktop appcasts and catalogs.','--latest=false')
        _,feed=inspect_remote(plan)
    # Fully stage the first feed privately before the app visibility flip.
    if feed['draft']:complete_feed(root,plan)
    release,_=inspect_remote(plan)
    if release.get('body')!=notes:raise ValueError('Release notes changed before publication')
    if release['draft']:
        write('release','edit',tag,'--repo',common.REPO,'--draft=false','--prerelease='+str(plan['prerelease']).lower(),'--latest=false' if plan['prerelease'] else '--latest=true')
    release,_=inspect_remote(plan)
    if release['draft'] or release.get('body')!=notes:raise ValueError('Application visibility or release notes verification failed')
    feed=complete_feed(root,plan)
    if feed['draft']:write('release','edit','desktop-updates','--repo',common.REPO,'--draft=false','--latest=false')
    release,feed=inspect_remote(plan)
    if release['draft'] or release.get('body')!=notes:raise ValueError('Published release notes changed')
    if feed['draft'] or any(not matches(assets(feed).get(n,{}),plan['files'][n],(root/n).stat().st_size) for n in FEED_FILES):raise ValueError('Publication remains incomplete; rerun the approved write job')


def main():
    parser=argparse.ArgumentParser()
    modes=parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--fetch-receipt')
    modes.add_argument('--execute',type=Path)
    parser.add_argument('--receipt',required=True,type=Path)
    args=parser.parse_args()
    common.require_main()
    if args.fetch_receipt is not None:
        fetch_receipt(args.fetch_receipt,args.receipt)
        return
    if not os.environ.get('GH_TOKEN'):
        raise ValueError('Set DESKTOP_RELEASE_TOKEN in the protected desktop-release environment')
    plan=read_receipt(args.receipt)
    with tempfile.TemporaryDirectory(prefix='desktop-protected-publication-') as directory:
        root=Path(directory)
        authenticate_downloads(plan,root,args.execute)
        publish(root,plan)


if __name__=='__main__':main()
