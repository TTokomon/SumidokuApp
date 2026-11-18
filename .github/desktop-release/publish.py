#!/usr/bin/env python3
"""Main-owned write phase. Consumes data from this run's read-only verifier.

No product checkout, PR module, compiler, app execution, installer or signing key.
"""
import argparse
import json
from pathlib import Path
import subprocess
import common

FEED_FILES=('appcast.xml','desktop-releases.json','desktop-releases.json.sig')


def descriptor(root):
    value=json.loads((root/'verified.json').read_text())
    if value.get('format')!=1 or value.get('repository')!=common.REPO or value.get('onlineChecks') is not True or value.get('toolingCommit')!=common.policy()['toolingCommit']:raise ValueError('Untrusted validation receipt')
    entry=common.selected(value['version'])
    if value.get('tag')!='desktop-v'+entry['version'] or value.get('sourceRevision')!=entry['sourceRevision'] or type(value.get('prerelease')) is not bool or value['prerelease']!=(entry['channel']=='beta'):raise ValueError('Validation plan does not match approved release')
    if type(value.get('files')) is not dict or set(value['files'])!=set(common.filenames(value['version'])):raise ValueError('Unexpected files in validation receipt')
    prior=value.get('priorFeed')
    if prior is not None and (type(prior) is not dict or set(prior)!={'appcast.xml','desktop-releases.json','desktop-releases.json.sig'} or any(not isinstance(v,str) or len(v)!=64 or any(c not in '0123456789abcdef' for c in v) for v in prior.values())):raise ValueError('Unsafe prior-feed receipt')
    actual={p.name for p in root.iterdir()}
    if actual!=set(common.filenames(value['version']))|{'verified.json'}:raise ValueError('Unexpected verified artifact')
    for name,limit in common.filenames(value['version']).items():
        p=root/name
        if not p.is_file() or p.is_symlink() or not 0<p.stat().st_size<=limit or common.sha(p)!=value['files'].get(name):raise ValueError('Verified artifact changed in transport')
    archive='Sumidoku-Desktop-'+value['version']+'-macOS-arm64.zip'
    if value['files'][archive]!=entry['sha256'] or (root/archive).stat().st_size!=entry['length']:raise ValueError('Archive is not the reviewed approved release')
    return value


def assets(release):
    items={a['name']:a for a in release['assets']}
    if len(items)!=len(release['assets']):raise ValueError('Duplicate remote assets')
    return items


def matches(asset,digest,size=None):
    return asset.get('digest')=='sha256:'+digest and (size is None or asset.get('size')==size)


def checked_release(tag,source,expected_names,root=None):
    release=common.maybe_release(tag)
    if release:
        if release['target_commitish']!=source or release['tag_name']!=tag:raise ValueError('Wrong-source release is immutable')
        remote=assets(release)
        if set(remote)-set(expected_names):raise ValueError('Release contains unexpected assets')
        if root is None:
            if not release['draft']:raise ValueError('Published release is immutable without exact artifact verification')
        else:
            if any(not matches(a,expected_names[n],(root/n).stat().st_size) for n,a in remote.items()):raise ValueError('Release asset digest or size changed; immutable')
            if not release['draft'] and set(remote)!=set(expected_names):raise ValueError('Published release is incomplete and immutable')
    return release


def inspect_remote(plan,root=None):
    release=checked_release(plan['tag'],plan['sourceRevision'],plan['files'],root)
    if release is not None and root is not None and release.get('prerelease') is not plan['prerelease']:raise ValueError('Release channel differs from the verified transaction')
    feed=common.maybe_release('desktop-updates');prior=plan['priorFeed']
    recovering=root is not None and release is not None and not release['draft']
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
                    if not recovering or not matches(item,plan['files'][name],(root/name).stat().st_size):raise ValueError('Published feed changed outside this transaction')
        else:
            # Only the first feed's same-source draft may be staged in advance.
            # A public feed is accepted only to finish the identical public app.
            if feed['target_commitish']!=plan['sourceRevision'] or (not feed['draft'] and not recovering):raise ValueError('Published feed changed since validation')
            if root is None or any(not matches(item,plan['files'][name],(root/name).stat().st_size) for name,item in remote.items()):raise ValueError('Feed contains unauthenticated transaction bytes')
    if plan['prerelease'] and not prior:raise ValueError('Public Stable must precede Beta')
    return release,feed


def write(*args):subprocess.run(['gh',*args],check=True)


def complete_feed(root,plan):
    _,feed=inspect_remote(plan,root)
    for name in FEED_FILES:
        # Recheck all state before each write, including an interrupted clobber.
        # Only prior authenticated or exact new feed bytes are accepted.
        _,feed=inspect_remote(plan,root);item=assets(feed).get(name)
        if item and matches(item,plan['files'][name],(root/name).stat().st_size):continue
        write('release','upload','desktop-updates',str(root/name),'--repo',common.REPO,*(['--clobber'] if item else []))
        _,feed=inspect_remote(plan,root);item=assets(feed).get(name)
        if item is None or not matches(item,plan['files'][name],(root/name).stat().st_size):raise ValueError('Feed upload digest or size mismatch')
    return feed


def publish(root):
    common.require_main()
    plan=descriptor(root);release,feed=inspect_remote(plan,root);tag=plan['tag']
    # Draft creation/local staging is a separate reviewed operation. This writer
    # never uploads application assets, even to a draft: a visibility race cannot
    # make an archive upload touch a public release.
    if release is None or set(assets(release))!=set(plan['files']):raise ValueError('Stage the complete matching application draft before publication')
    if feed is None:
        write('release','create','desktop-updates','--repo',common.REPO,'--target',plan['sourceRevision'],'--draft','--title','Desktop signed update feeds','--notes','Publisher-authenticated desktop appcasts and catalogs.','--latest=false')
        _,feed=inspect_remote(plan,root)
    # Fully stage the first feed privately before the app visibility flip.
    if feed['draft']:complete_feed(root,plan)
    release,_=inspect_remote(plan,root)
    if release['draft']:
        write('release','edit',tag,'--repo',common.REPO,'--draft=false','--prerelease='+str(plan['prerelease']).lower(),'--latest=false' if plan['prerelease'] else '--latest=true')
    release,_=inspect_remote(plan,root)
    if release['draft']:raise ValueError('Application visibility change did not complete')
    feed=complete_feed(root,plan)
    if feed['draft']:write('release','edit','desktop-updates','--repo',common.REPO,'--draft=false','--latest=false')
    _,feed=inspect_remote(plan,root)
    if feed['draft'] or any(not matches(assets(feed).get(n,{}),plan['files'][n],(root/n).stat().st_size) for n in FEED_FILES):raise ValueError('Publication remains incomplete; rerun the approved write job')


def main():
    p=argparse.ArgumentParser();p.add_argument('artifacts',type=Path);p.add_argument('--execute',action='store_true');p.add_argument('--inspect-remote',action='store_true');a=p.parse_args()
    if a.execute:publish(a.artifacts)
    else:
        value=descriptor(a.artifacts)
        if a.inspect_remote:inspect_remote(value,a.artifacts)
        print('PASS: publication preflight; no write performed')
if __name__=='__main__':main()
