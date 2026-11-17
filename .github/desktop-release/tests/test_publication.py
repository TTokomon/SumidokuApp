import copy
import importlib.util
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
            with self.assertRaisesRegex(ValueError,'main workflow'):writer.publish(Path('.'))
            write.assert_not_called()
    def test_workflow_privileges_are_separate(self):
        text=(BASE.parent/'workflows/desktop-publish.yml').read_text();before,write=text.split('\n  publish:\n',1)
        self.assertNotIn('contents: write',before)
        self.assertIn("github.ref == 'refs/heads/main'",write)
        self.assertIn('inputs.verify_only == false',write)
        self.assertIn('environment: desktop-release',write)
        self.assertNotIn('TrustTool',write);self.assertNotIn('swiftc',write);self.assertNotIn('publish_release.py',write)
        self.assertNotIn('secrets.',text)
    def test_offline_or_injected_validation_receipt_is_not_publishable(self):
        value={'format':1,'repository':common.REPO,'onlineChecks':False,'toolingCommit':common.policy()['toolingCommit']}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);p=root/'verified.json';p.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError,'Untrusted'):writer.descriptor(root)
            entry=common.selected(VERSION);value.update({'onlineChecks':True,'version':VERSION,'tag':'desktop-v'+VERSION,'sourceRevision':entry['sourceRevision'],'prerelease':False,'files':{'../outside':'a'*64},'priorFeed':None});p.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError,'Unexpected files'):writer.descriptor(root)
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
        for value in [{'draft':False,'target_commitish':'a'*40,'tag_name':'desktop-v'+VERSION,'assets':[]},{'draft':True,'target_commitish':'wrong','tag_name':'desktop-v'+VERSION,'assets':[]}]:
            with patch.object(common,'maybe_release',return_value=value):
                with self.assertRaisesRegex(ValueError,'immutable'):writer.checked_release('desktop-v'+VERSION,'a'*40,{})
    def test_new_feed_may_not_appear_between_validation_and_write(self):
        with patch.object(writer,'checked_release',return_value=None),patch.object(common,'maybe_release',return_value={'draft':False}):
            with self.assertRaisesRegex(ValueError,'changed'):writer.inspect_remote({'tag':'desktop-v'+VERSION,'sourceRevision':'a'*40,'files':{},'priorFeed':None})
    def test_beta_requires_public_stable(self):
        with patch.object(common,'maybe_release',return_value=None):
            with self.assertRaisesRegex(ValueError,'Stable'):validate.prior_feed(None,'1.3.1-beta.1',None)
    def test_network_failure_is_not_absence(self):
        result=type('Response',(),{'returncode':1,'stdout':'','stderr':'gh: API rate limit exceeded (HTTP 403)'})()
        with patch.object(common.subprocess,'run',return_value=result):
            with self.assertRaisesRegex(RuntimeError,'nothing may be published'):common.maybe_release('desktop-updates')

if __name__=='__main__':unittest.main()
