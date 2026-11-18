#!/usr/bin/env python3
"""Read-only validation using an immutable reviewed verifier, never a PR ref."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import sys
import common


def materialize(repo,output):
    rules=common.policy();revision=rules['toolingCommit']
    if not re.fullmatch('[a-f0-9]{40}',revision):raise ValueError('Tooling must use an immutable reviewed commit')
    for name,digest in rules['toolingFiles'].items():
        if name.startswith('/') or '..' in Path(name).parts:raise ValueError('Unsafe verifier source path')
        raw=subprocess.check_output(['git','-C',str(repo),'show',revision+':'+name])
        import hashlib
        if hashlib.sha256(raw).hexdigest()!=digest:raise ValueError('Reviewed verifier source hash mismatch: '+name)
        target=output/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
    return output


def build_tool(source,output):
    rules=common.policy()
    files=[str(source/name) for name in rules['toolingFiles'] if name.endswith('.swift')]
    # No product build script, package manager, workflow from a PR or arbitrary ref.
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(output.parent/'ModuleCache'),*files,'-o',str(output)],check=True)


def retrieve(root,version,tag,run):
    if bool(tag)==bool(run):raise ValueError('Choose exactly one staged draft or candidate run')
    rules=common.policy()
    if tag:
        if tag!='desktop-v'+version:raise ValueError('Draft tag/version mismatch')
        transport=os.environ.get('SUMIDOKU_DRAFT_TRANSPORT','')
        if transport:
            assets=common.draft_transport(transport,version,tag)
            for name,asset in assets.items():common.download_capability(asset,root/name)
            return
        release=common.maybe_release(tag)
        if release is None or not release['draft'] or release['target_commitish']!=common.selected(version)['sourceRevision']:raise ValueError('Expected the matching unpublished draft')
        assets={a['name']:a for a in release['assets']}
        if len(assets)!=len(release['assets']) or set(assets)!=set(common.filenames(version)):raise ValueError('Unexpected or missing draft assets')
        for name,limit in common.filenames(version).items():common.download_asset(assets[name],root/name,limit)
    else:
        if not re.fullmatch('[1-9][0-9]*',run):raise ValueError('Invalid candidate run')
        value=common.gh_json('api',f'repos/{common.REPO}/actions/runs/{run}')
        if value['conclusion']!='success' or value['event']!='workflow_dispatch' or value['path']!='.github/workflows/desktop-candidate.yml' or value['head_sha']!=rules['reviewedApplicationCommit']:raise ValueError('Unreviewed or unsuccessful candidate workflow')
        items=common.gh_json('api',f'repos/{common.REPO}/actions/runs/{run}/artifacts')['artifacts']
        items=[a for a in items if a['name'].startswith('desktop-unpublished-'+version+'-') and not a['expired']]
        if len(items)!=1 or items[0]['size_in_bytes']>536_870_912:raise ValueError('Ambiguous or oversized workflow artifact')
        package=root.parent/'candidate.zip'
        # Artifact id is from this exact successful, reviewed workflow run.
        if type(items[0]['id']) is not int:raise ValueError('Invalid artifact id')
        common.download_stream(f'repos/{common.REPO}/actions/artifacts/{items[0]["id"]}/zip',package,536_870_912)
        if package.stat().st_size>536_870_912:raise ValueError('Oversized candidate transport')
        common.unpack_artifact(package,root)


def verify(root,version,source,tool):
    rules=common.policy();hashes=common.file_set(root,version)
    spec=importlib.util.spec_from_file_location('reviewed_verifier',source/'macos/Distribution/publish_release.py')
    verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)
    plan,entry,archive=verifier.verify(root,tool,rules['publicKey'])
    notices = Path(__file__).resolve().parents[2] / "macos/Distribution/release_notices.py"
    subprocess.run([sys.executable, str(notices), str(archive)], check=True)
    if entry!=common.selected(version):raise ValueError('Artifact is not the reviewed approved release')
    catalog=json.loads((root/'desktop-releases.json').read_text())
    if any(item!=rules['approvedReleases'].get(item['version']) for item in catalog['releases']):raise ValueError('Catalog advertises an unreviewed release')
    proof=json.loads((root/'release-qualification.json').read_text())
    if proof.get('reviewedHead')!=rules['reviewedApplicationCommit']:raise ValueError('Qualification is for an unreviewed application revision')
    # Signed inventory must bind notes and plan as well as the app and feeds.
    inventory={line.split('  ',1)[1]:line.split('  ',1)[0] for line in (root/'SHA256SUMS').read_text().splitlines()}
    expected=set(common.filenames(version))-{'SHA256SUMS','release-qualification.json','release-qualification.json.sig'}
    if set(inventory)!=expected or any(inventory[n]!=hashes[n] for n in expected):raise ValueError('Incomplete signed inventory coverage')
    return plan,entry,hashes


def prior_feed(tool,version,work):
    feed=common.maybe_release('desktop-updates')
    if feed is None:
        if common.selected(version)['channel']=='beta':raise ValueError('Stable must be publicly published and verified before Beta')
        return None
    if feed['draft']:raise ValueError('Existing feed is not public')
    assets={a['name']:a for a in feed['assets']};names=['desktop-releases.json','desktop-releases.json.sig','appcast.xml']
    if any(n not in assets for n in names):raise ValueError('Published feed is incomplete')
    for name in names:common.download_asset(assets[name],work/name,common.META[name])
    subprocess.run([str(tool),'catalog',str(work/'desktop-releases.json'),str(work/'desktop-releases.json.sig'),common.policy()['publicKey']],check=True)
    return {name:common.sha(work/name) for name in names}


def main():
    p=argparse.ArgumentParser();p.add_argument('--repo',type=Path,required=True);p.add_argument('--version',required=True);p.add_argument('--artifacts',type=Path);p.add_argument('--staged-tag',default='');p.add_argument('--candidate-run-id',default='');p.add_argument('--output',type=Path);p.add_argument('--offline',action='store_true');p.add_argument('--check-policy',action='store_true');a=p.parse_args()
    common.selected(a.version)
    with tempfile.TemporaryDirectory(prefix='desktop-readonly-validation-') as temporary:
        work=Path(temporary);source=materialize(a.repo,work/'reviewed-source');tool=work/'TrustTool';build_tool(source,tool)
        if a.check_policy:
            print('PASS: reviewed tooling hashes and verifier compilation; no artifact or write permission used');return
        if a.output is None:raise ValueError('An output directory is required')
        root=a.artifacts
        if root is None:root=work/'input';root.mkdir();retrieve(root,a.version,a.staged_tag,a.candidate_run_id)
        plan,entry,hashes=verify(root,a.version,source,tool)
        if a.offline:
            prior=None
        else:
            checks=common.gh_json('api',f'repos/{common.REPO}/commits/{common.policy()["reviewedApplicationCommit"]}/check-runs')['check_runs']
            if not any(c['name']=='ci' and c['status']=='completed' and c['conclusion']=='success' for c in checks):raise ValueError('Required reviewed application CI is not green')
            (work/'prior').mkdir();prior=prior_feed(tool,a.version,work/'prior')
            for item in json.loads((root/'desktop-releases.json').read_text())['releases']:
                if item['version']==a.version:continue
                published=common.maybe_release('desktop-v'+item['version'])
                assets={x['name']:x for x in published['assets']} if published else {}
                archive='Sumidoku-Desktop-'+item['version']+'-macOS-arm64.zip'
                if not published or published['draft'] or archive not in assets or assets[archive].get('digest')!='sha256:'+item['sha256'] or assets[archive]['size']!=item['length']:raise ValueError('Catalog references a release that is not publicly verified')
            if prior:
                old=json.loads((work/'prior/desktop-releases.json').read_text())['releases'];new=json.loads((root/'desktop-releases.json').read_text())['releases']
                if any(item not in new for item in old) or (entry['channel']=='beta' and not any(item['channel']=='stable' for item in old)):raise ValueError('Published Stable/release entries must be preserved')
        a.output.mkdir(mode=0o700)
        import shutil
        for name in hashes:shutil.copyfile(root/name,a.output/name)
        descriptor={'format':1,'repository':common.REPO,'version':a.version,'tag':plan['tag'],'sourceRevision':entry['sourceRevision'],'prerelease':entry['channel']=='beta','files':hashes,'priorFeed':prior,'onlineChecks':not a.offline,'toolingCommit':common.policy()['toolingCommit']}
        (a.output/'verified.json').write_text(json.dumps(descriptor,sort_keys=True)+'\n')
        print('PASS: authenticated reviewed release; no publication permission or signing key used')
if __name__=='__main__':main()
