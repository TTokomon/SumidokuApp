"""An incomplete qualification must never reach GitHub release mutation."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('publish_release',Path(__file__).resolve().parents[1]/'Distribution/publish_release.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.key=base64.b64encode(bytes(32)).decode();self.tool=self.root/'TrustTool'
        self.archive=self.root/'Sumidoku-Desktop-1.3.0+community.1-macOS-arm64.zip';self.archive.write_bytes(b'fixture archive')
        entry={'version':'1.3.0+community.1','build':9,'channel':'stable','sourceRevision':'a'*40,'url':'https://github.com/TTokomon/SumidokuApp/releases/download/desktop-v1.3.0+community.1/'+self.archive.name,'length':self.archive.stat().st_size,'sha256':module.sha(self.archive)}
        (self.root/'desktop-releases.json').write_text(json.dumps({'releases':[entry]}));(self.root/'desktop-releases.json.sig').write_text('fixture signature; trust tool mocked')
        (self.root/'appcast.xml').write_text('fixture appcast')
        (self.root/'release-plan.json').write_text(json.dumps({'tag':'desktop-v1.3.0+community.1','prerelease':False,'draft':True,'published':False}))
        self.proof={'version':entry['version'],'build':entry['build'],'archiveSha256':entry['sha256'],'format':1,'status':'passed','sourceRevision':'a'*40,'checks':sorted(module.REQUIRED),'catalogSha256':module.sha(self.root/'desktop-releases.json'),'appcastSha256':module.sha(self.root/'appcast.xml')};self.write()
        (self.root/'release-qualification.json.sig').write_text('fixture signature; trust tool mocked')
        files=[self.archive,self.root/'desktop-releases.json',self.root/'desktop-releases.json.sig',self.root/'appcast.xml']
        (self.root/'SHA256SUMS').write_text(''.join(f'{module.sha(p)}  {p.name}\n' for p in files))
        self.proof['inventorySha256']=module.sha(self.root/'SHA256SUMS');self.write()
    def tearDown(self):self.temp.cleanup()
    def write(self):(self.root/'release-qualification.json').write_text(json.dumps(self.proof))
    def assert_blocked_before_github(self,pattern):
        with patch.object(module.subprocess,'run') as commands:
            with self.assertRaisesRegex(ValueError,pattern):module.publish(self.root,self.tool,self.key)
            self.assertFalse(any(call.args[0]=='gh' or (isinstance(call.args[0],list) and call.args[0][0]=='gh') for call in commands.call_args_list))
    def test_unrun_or_failed_check_blocks_publication(self):
        self.proof['checks'].remove('native-community-roundtrip');self.write();self.assert_blocked_before_github('Incomplete')
        self.proof['checks']=sorted(module.REQUIRED);self.proof['status']='failed';self.write();self.assert_blocked_before_github('Incomplete')
    def test_appcast_or_catalog_substitution_blocks_publication(self):
        (self.root/'appcast.xml').write_text('modified feed');self.assert_blocked_before_github('exact artifacts')
    def test_wrong_source_provenance_blocks_publication(self):
        self.proof['sourceRevision']='b'*40;self.write();self.assert_blocked_before_github('provenance mismatch')
    def test_changed_archive_blocks_publication(self):
        self.archive.write_bytes(b'modified archive');self.assert_blocked_before_github('archive mismatch')
    def test_checksum_path_traversal_blocks_publication(self):
        with (self.root/'SHA256SUMS').open('a') as stream:stream.write('a'*64+'  ../outside\n')
        self.proof['inventorySha256']=module.sha(self.root/'SHA256SUMS');self.write()
        self.assert_blocked_before_github('Unsafe checksum')
    def test_qualification_cannot_be_reused_for_a_different_build(self):
        self.proof['build']=10;self.write();self.assert_blocked_before_github('exact version/build/archive')
    def test_local_staging_refuses_published_or_wrong_source_release(self):
        for metadata in [{'isDraft':False,'targetCommitish':'a'*40,'tagName':'desktop-v1.3.0+community.1'},{'isDraft':True,'targetCommitish':'b'*40,'tagName':'desktop-v1.3.0+community.1'}]:
            with patch.object(module.subprocess,'run') as commands,patch.object(module.subprocess,'check_output',return_value=json.dumps(metadata)):
                with self.assertRaisesRegex(ValueError,'matching unpublished'):module.stage_local(self.root,self.tool,self.key)
                self.assertFalse(any(isinstance(c.args[0],str) and c.args[0]=='gh' for c in commands.call_args_list))
    def test_beta_cannot_publish_before_a_verified_stable_feed(self):
        plan={'tag':'desktop-v1.3.1-beta.1','prerelease':True};entry={'channel':'beta'}
        with patch.object(module,'verify',return_value=(plan,entry,self.archive)),patch.object(module.subprocess,'run') as commands:
            commands.return_value.returncode=1
            with self.assertRaisesRegex(ValueError,'Stable feed'):module.publish(self.root,self.tool,self.key)
            self.assertFalse(any(isinstance(c.args[0],str) and c.args[0]=='gh' for c in commands.call_args_list))
    def test_channel_mismatch_cannot_publish_beta_as_stable(self):
        p=self.root/'release-plan.json';value=json.loads(p.read_text());value['prerelease']=True;p.write_text(json.dumps(value));self.assert_blocked_before_github('channel mismatch')

if __name__=='__main__':unittest.main()
