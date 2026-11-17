#!/usr/bin/env python3
"""Main-owned write phase. Consumes data from this run's read-only verifier.

No product checkout, PR module, compiler, app execution, installer or signing key.
"""
import argparse
import json
from pathlib import Path
import subprocess
import common


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
    return value


def checked_release(tag,source,expected_names):
    release=common.maybe_release(tag)
    if release and (not release['draft'] or release['target_commitish']!=source or release['tag_name']!=tag):raise ValueError('Published release or wrong-source draft is immutable')
    if release and any(a['name'] not in expected_names for a in release['assets']):raise ValueError('Draft contains unexpected assets')
    return release


def inspect_remote(plan):
    release=checked_release(plan['tag'],plan['sourceRevision'],plan['files'])
    feed=common.maybe_release('desktop-updates');prior=plan['priorFeed']
    if bool(feed)!=bool(prior):raise ValueError('Published feed changed since validation')
    if feed:
        if feed['draft']:raise ValueError('Existing feed is not public')
        assets={a['name']:a for a in feed['assets']}
        for name,digest in prior.items():
            if name not in assets or assets[name].get('digest')!='sha256:'+digest:raise ValueError('Published feed digest changed or unavailable')
    if plan['prerelease'] and not prior:raise ValueError('Public Stable must precede Beta')
    return release,feed


def write(*args):subprocess.run(['gh',*args],check=True)

def publish(root):
    common.require_main()
    plan=descriptor(root);release,feed=inspect_remote(plan);tag=plan['tag']
    if release is None:
        write('release','create',tag,'--repo',common.REPO,'--target',plan['sourceRevision'],'--draft','--title','Sumidoku Desktop '+plan['version'],'--notes-file',str(root/'RELEASE_NOTES.md'),*(['--prerelease'] if plan['prerelease'] else []))
    # Upload only the exact bytes validated in the read-only job, then verify the
    # GitHub asset digests before making the draft public.
    write('release','upload',tag,*[str(root/name) for name in plan['files']],'--repo',common.REPO,'--clobber')
    uploaded=checked_release(tag,plan['sourceRevision'],plan['files'])
    assets={a['name']:a for a in uploaded['assets']}
    if set(assets)!=set(plan['files']) or any(assets[n].get('digest')!='sha256:'+digest or assets[n]['size']!=(root/n).stat().st_size for n,digest in plan['files'].items()):raise ValueError('Staged GitHub bytes do not match verified files; draft remains unpublished')
    # An operator may have changed the feed while the draft uploaded. Recheck.
    inspect_remote(plan)
    write('release','edit',tag,'--repo',common.REPO,'--draft=false','--prerelease='+str(plan['prerelease']).lower(),'--latest=false' if plan['prerelease'] else '--latest=true')
    if feed is None:
        write('release','create','desktop-updates','--repo',common.REPO,'--target',plan['sourceRevision'],'--title','Desktop signed update feeds','--notes','Publisher-authenticated desktop appcasts and catalogs.','--latest=false')
    write('release','upload','desktop-updates',*[str(root/n) for n in ['appcast.xml','desktop-releases.json','desktop-releases.json.sig']],'--repo',common.REPO,'--clobber')


def main():
    p=argparse.ArgumentParser();p.add_argument('artifacts',type=Path);p.add_argument('--execute',action='store_true');p.add_argument('--inspect-remote',action='store_true');a=p.parse_args()
    if a.execute:publish(a.artifacts)
    else:
        value=descriptor(a.artifacts)
        if a.inspect_remote:inspect_remote(value)
        print('PASS: publication preflight; no write performed')
if __name__=='__main__':main()
