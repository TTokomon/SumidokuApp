import copy
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
import common
import validate
spec=importlib.util.spec_from_file_location('writer',BASE/'publish.py');writer=importlib.util.module_from_spec(spec);spec.loader.exec_module(writer)
VERSION='1.3.0+community.1'
class PublicationTests(unittest.TestCase):
    def transport(self):
        entry=common.selected(VERSION)
        assets={n:{'url':'https://release-assets.githubusercontent.com/package/file?sig=read-only-fixture','size':4,'sha256':'a'*64} for n in common.filenames(VERSION)}
        assets['Sumidoku-Desktop-'+VERSION+'-macOS-arm64.zip'].update(size=entry['length'],sha256=entry['sha256'])
        return {'format':1,'repository':common.REPO,'tag':'desktop-v'+VERSION,'sourceRevision':entry['sourceRevision'],'draft':True,'releaseId':123,'created':1000,'expires':2200,'assets':assets}
    def test_draft_capabilities_are_exact_short_lived_and_package_bound(self):
        value=self.transport()
        with patch.object(common.time,'time',return_value=1001):
            self.assertEqual(common.draft_transport(json.dumps(value),VERSION,value['tag']),value)
            for field,replacement in [('draft',False),('sourceRevision','b'*40),('expires',9999),('assets',{})]:
                changed=copy.deepcopy(value);changed[field]=replacement
                with self.subTest(field=field),self.assertRaises(ValueError):common.draft_transport(json.dumps(changed),VERSION,value['tag'])
            value['assets']['Sumidoku-Desktop-'+VERSION+'-macOS-arm64.zip']['sha256']='b'*64
            with self.assertRaisesRegex(ValueError,'not approved'):common.draft_transport(json.dumps(value),VERSION,value['tag'])
    def test_expired_or_non_github_capabilities_are_rejected(self):
        value=self.transport()
        with patch.object(common.time,'time',return_value=2201):
            with self.assertRaisesRegex(ValueError,'Expired'):common.draft_transport(json.dumps(value),VERSION,value['tag'])
        for url in ['http://release-assets.githubusercontent.com/a?sig=x','https://evil.example/a?sig=x','https://user@release-assets.githubusercontent.com/a?sig=x','https://release-assets.githubusercontent.com/a?sig=x#fragment','https://release-assets.githubusercontent.com:8443/a?sig=x']:
            value=self.transport();value['assets']['SHA256SUMS']['url']=url
            with patch.object(common.time,'time',return_value=1001),self.subTest(url=url),self.assertRaisesRegex(ValueError,'Unsafe'):common.draft_transport(json.dumps(value),VERSION,value['tag'])
    def test_capability_download_enforces_hash_size_and_no_redirects(self):
        asset={'url':'https://release-assets.githubusercontent.com/a?sig=never-log-me','size':4,'sha256':hashlib.sha256(b'data').hexdigest()}
        self.assertIsNone(common.NoRedirect().redirect_request(None,None,None,None,None,None))
        for payload,valid in [(b'data',True),(b'bad!',False),(b'excess',False),(b'cut',False)]:
            with tempfile.TemporaryDirectory() as directory,patch.object(common.urllib.request,'build_opener') as opener:
                opener.return_value.open.return_value=io.BytesIO(payload)
                if valid:common.download_capability(asset,Path(directory)/'asset')
                else:
                    with self.assertRaises(ValueError) as error:common.download_capability(asset,Path(directory)/'asset')
                    self.assertNotIn('never-log-me',str(error.exception))
    def test_intel_runner_preserves_macos_and_arm64_verification(self):
        workflow=(BASE.parent/'workflows/desktop-publish.yml').read_text()
        validation=workflow.split('\n  validate:\n',1)[1].split('\n  publish:\n',1)[0]
        self.assertIn('runs-on: macos-26-intel',validation)
        self.assertIn('validate.py --repo .',validation)
        self.assertNotIn('--offline',validation)
        build=(BASE.parent/'workflows/ci.yml').read_text().split('\n  build:\n',1)[1].split('\n  web:\n',1)[0]
        self.assertIn('macos-26-intel',build)
        self.assertIn('rustup target add aarch64-apple-darwin',build)
        self.assertIn("runner.os == 'macOS' && '--target aarch64-apple-darwin'",build)
    def test_draft_found_after_tag_endpoint_returns_404(self):
        result=type('Response',(),{'returncode':1,'stdout':'','stderr':'gh: Not Found (HTTP 404)'})()
        draft={'tag_name':'desktop-v'+VERSION,'draft':True}
        with patch.object(common.subprocess,'run',return_value=result),patch.object(common,'gh_json',side_effect=[[{'tag_name':'other'}]*100,[draft]]) as lookup:
            self.assertEqual(common.maybe_release(draft['tag_name']),draft)
            self.assertEqual(lookup.call_count,2)
    def test_draft_list_failure_is_not_absence(self):
        result=type('Response',(),{'returncode':1,'stdout':'','stderr':'gh: Not Found (HTTP 404)'})()
        with patch.object(common.subprocess,'run',return_value=result),patch.object(common,'gh_json',side_effect=RuntimeError('HTTP 403')):
            with self.assertRaisesRegex(RuntimeError,'403'):common.maybe_release('missing')
    def test_release_absence_requires_complete_list(self):
        result=type('Response',(),{'returncode':1,'stdout':'','stderr':'gh: Not Found (HTTP 404)'})()
        with patch.object(common.subprocess,'run',return_value=result),patch.object(common,'gh_json',return_value=[]):
            self.assertIsNone(common.maybe_release('missing'))
        with patch.object(common.subprocess,'run',return_value=result),patch.object(common,'gh_json',return_value=[{'tag_name':'other'}]*100):
            with self.assertRaisesRegex(ValueError,'pagination'):common.maybe_release('missing')
    def test_source_hash_mismatch_rejected_before_compiler(self):
        with tempfile.TemporaryDirectory() as directory,patch.object(validate.subprocess,'check_output',return_value=b'changed verifier'),patch.object(validate.subprocess,'run') as execute:
            with self.assertRaisesRegex(ValueError,'hash mismatch'):validate.materialize(Path(directory),Path(directory)/'out')
            execute.assert_not_called()
    def test_arbitrary_tooling_ref_rejected(self):
        value=copy.deepcopy(common.policy());value['toolingCommit']='refs/pull/4/head'
        with patch.object(common,'policy',return_value=value):
            with self.assertRaisesRegex(ValueError,'immutable'):validate.materialize(Path('.'),Path('.'))
    def test_only_reviewed_versions_allowed(self):
        with self.assertRaisesRegex(ValueError,'reviewed'):common.selected('9.9.9-beta.1')
    def test_main_only_write_boundary(self):
        with patch.dict(os.environ,{'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':common.REPO,'GITHUB_REF':'refs/heads/fix/trusted-desktop-publication','GITHUB_WORKFLOW_REF':common.REPO+'/.github/workflows/desktop-publish.yml@refs/heads/main'}):
            with self.assertRaisesRegex(ValueError,'main workflow'):common.require_main()
    def test_local_or_pr_execution_cannot_publish(self):
        with patch.dict(os.environ,{},clear=True),patch.object(writer,'write') as write:
            with self.assertRaisesRegex(ValueError,'main workflow'):writer.publish(Path('.'),{})
            write.assert_not_called()
    def test_workflow_privileges_are_separate(self):
        text=(BASE.parent/'workflows/desktop-publish.yml').read_text();before,write=text.split('\n  publish:\n',1)
        self.assertNotIn('contents: write',before)
        self.assertIn("github.ref == 'refs/heads/main'",write)
        self.assertIn('inputs.verify_only == false',write)
        self.assertIn('environment: desktop-release',write)
        self.assertIn('--prepare-tool',write);self.assertNotIn('publish_release.py',write)
        self.assertEqual(before.count('secrets.'),1)
        self.assertIn('secrets.DESKTOP_DRAFT_TRANSPORT',text)
        self.assertNotIn('PRIVATE_KEY',text)
    def test_release_credential_is_confined_to_final_protected_step(self):
        text = (BASE.parent / 'workflows/desktop-publish.yml').read_text()
        staging, release = text.split('      - name: Publish using main-owned code only after environment approval\n', 1)
        self.assertNotIn('DESKTOP_RELEASE_TOKEN', staging)
        self.assertNotIn('contents: write', text)
        self.assertIn('GH_TOKEN: ${{ github.token }}', staging.split('  publish:\n', 1)[1])
        self.assertEqual(release.count('secrets.DESKTOP_RELEASE_TOKEN'), 1)
        self.assertNotIn('github.token', release)
        self.assertNotIn('      - ', release)

    def test_draft_creation_requires_protected_credential_and_exact_policy_source(self):
        import subprocess
        import textwrap

        workflow = BASE.parent / 'workflows/desktop-local-draft.yml'
        workflow_text = workflow.read_text()
        self.assertIn("github.ref == 'refs/heads/main'", workflow_text)
        self.assertIn('environment: desktop-release', workflow_text)
        self.assertNotIn('contents: write', workflow_text)
        before, step = workflow_text.split('      - name: Create an empty unpublished draft only\n', 1)
        self.assertNotIn('secrets.', before)
        self.assertIn('persist-credentials: false', before)
        self.assertEqual(step.count('secrets.DESKTOP_RELEASE_TOKEN'), 1)
        command = textwrap.dedent(step.split('        run: |\n', 1)[1])
        stub = r"""#!/bin/bash
if [ "$1 $2" = 'release create' ]; then printf '%s\n' "$@"; exit; fi
if [ "$2" = 'repos/TTokomon/SumidokuApp/releases' ]; then
    if [ "$FAKE_LIST" = 'denied' ]; then exit 1; fi
    printf '%s\n' "$FAKE_LIST"
fi
if [[ "$2" == repos/TTokomon/SumidokuApp/git/matching-refs/tags/* ]]; then
    printf '%s\n' "$FAKE_REF"
fi
"""
        source = common.selected(VERSION)['sourceRevision']
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'gh'
            executable.write_text(stub)
            executable.chmod(0o700)
            for token, revision, listed, ref, succeeds in [
                ('', source, '', '', False),
                ('test-only', '0' * 40, '', '', False),
                ('test-only', source, 'denied', '', False),
                ('test-only', source, 'desktop-v' + VERSION, '', False),
                ('test-only', source, '', 'refs/tags/desktop-v' + VERSION, False),
                ('test-only', source, '', '', True),
            ]:
                with self.subTest(credential=bool(token), source_pinned=revision == source, listed=listed, ref=ref):
                    result = subprocess.run(
                        ['bash', '-e', '-c', command], cwd=BASE.parent.parent,
                        env={**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH'],
                             'GH_TOKEN': token, 'SOURCE_SHA': revision, 'DESKTOP_VERSION': VERSION,
                             'FAKE_LIST': listed, 'FAKE_REF': ref},
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                    args = result.stdout.splitlines()
                    self.assertEqual(bool(args), succeeds)
                    if succeeds:
                        self.assertIn('--draft', args)
                        self.assertNotIn('--draft=false', args)
                        self.assertEqual(args[args.index('--target') + 1], source)

    def test_missing_release_credential_refuses_to_invoke_writer(self):
        import subprocess
        import textwrap

        text = (BASE.parent / 'workflows/desktop-publish.yml').read_text()
        step = text.split('      - name: Publish using main-owned code only after environment approval\n', 1)[1]
        command = textwrap.dedent(step.split('        run: |\n', 1)[1])
        for credential, status in [('', 1), ('fixture-only', 0)]:
            with self.subTest(credential_present=bool(credential)):
                result = subprocess.run(
                    ['bash', '-e', '-c', 'python3() { echo writer-called; }\n' + command],
                    env={'GH_TOKEN': credential, 'RUNNER_TEMP': '/fixture'},
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual('writer-called' in result.stdout, bool(credential))

    def test_offline_or_injected_validation_receipt_is_not_publishable(self):
        value={'format':1,'repository':common.REPO,'onlineChecks':False,'toolingCommit':common.policy()['toolingCommit']}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/'verified.json';p.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError,'Untrusted'):writer.read_receipt(p)
            entry=common.selected(VERSION);value.update({'onlineChecks':True,'version':VERSION,'tag':'desktop-v'+VERSION,'sourceRevision':entry['sourceRevision'],'prerelease':False,'files':{'../outside':'a'*64},'priorFeed':None});p.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError,'Untrusted'):writer.read_receipt(p)
    def test_read_only_test_cannot_publish(self):
        text=(BASE.parent/'workflows/desktop-publish.yml').read_text()
        self.assertIn('default: true',text);self.assertIn('inputs.policy_test == false && inputs.verify_only == false',text)
    def test_transport_rejects_escape_symlink_and_duplicate(self):
        for names,mode in [(['../outside'],0),(['release-plan.json'],stat.S_IFLNK|0o777),(['release-plan.json','release-plan.json'],0)]:
            with self.subTest(names=names),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);archive=root/'artifact.zip';out=root/'out';out.mkdir()
                with zipfile.ZipFile(archive,'w') as package:
                    for name in names:
                        item=zipfile.ZipInfo(name);item.external_attr=mode<<16;package.writestr(item,b'fixture')
                with self.assertRaisesRegex(ValueError,'Unsafe'):common.unpack_artifact(archive,out)
    def test_artifact_set_rejects_added_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name in common.filenames(VERSION):(root/name).write_bytes(b'fixture')
            (root/'injected.py').write_bytes(b'print("not executed")')
            with self.assertRaisesRegex(ValueError,'Unexpected'):common.file_set(root,VERSION)
    def test_only_matching_drafts_can_be_modified(self):
        plan={'tag':'desktop-v'+VERSION,'sourceRevision':'a'*40,'files':{'expected':'b'*64},'sizes':{'expected':4},'prerelease':False,'releaseId':123}
        release={'id':123,'draft':True,'prerelease':False,'target_commitish':'a'*40,'tag_name':plan['tag'],'assets':[]}
        with patch.object(common,'maybe_release',return_value=release):
            with self.assertRaisesRegex(ValueError,'complete'):writer.checked_release(plan)
            release['target_commitish']='wrong'
            with self.assertRaisesRegex(ValueError,'identity'):writer.checked_release(plan)

    def test_new_feed_may_not_appear_between_validation_and_write(self):
        with patch.object(writer,'checked_release',return_value={'draft':True}),patch.object(common,'maybe_release',return_value={'draft':False,'tag_name':'desktop-updates','target_commitish':'a'*40,'assets':[]}):
            with self.assertRaisesRegex(ValueError,'changed'):writer.inspect_remote({'tag':'desktop-v'+VERSION,'sourceRevision':'a'*40,'files':{},'priorFeed':None})

    def test_workflow_uploads_only_the_receipt(self):
        text=(BASE.parent/'workflows/desktop-publish.yml').read_text()
        before,protected=text.split('\n  publish:\n',1)
        paths=[line.strip() for line in before.splitlines() if line.strip().startswith('path:')]
        self.assertEqual(paths,['path: ${{ runner.temp }}/desktop-verified/verified.json'])
        self.assertEqual(before.count('actions/upload-artifact@'),1)
        self.assertNotIn('actions/upload-artifact@',protected)
        self.assertIn('environment: desktop-release',protected)

    def test_beta_requires_public_stable(self):
        with patch.object(common,'maybe_release',return_value=None),patch.object(common,'selected',return_value={'channel':'beta'}):
            with self.assertRaisesRegex(ValueError,'Stable'):validate.prior_feed(None,'1.3.1-beta.1',None)
    def test_network_failure_is_not_absence(self):
        result=type('Response',(),{'returncode':1,'stdout':'','stderr':'gh: API rate limit exceeded (HTTP 403)'})()
        with patch.object(common.subprocess,'run',return_value=result):
            with self.assertRaisesRegex(RuntimeError,'nothing may be published'):common.maybe_release('desktop-updates')

if __name__=='__main__':unittest.main()
