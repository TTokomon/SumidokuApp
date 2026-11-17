"""Packaging must fail closed before creating or overwriting release artifacts."""
import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('prepare_release',Path(__file__).resolve().parents[1]/'Distribution/prepare_release.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='sumidoku-package-fixture-');self.root=Path(self.temp.name)
        self.app=self.root/'Sumidoku.app';(self.app/'Contents/Resources').mkdir(parents=True);(self.app/'Contents/MacOS').mkdir()
        self.info={'SumidokuReleaseVersion':'1.3.1-beta.1','CFBundleVersion':'8','SumidokuDevelopmentBuild':False,'SumidokuReleaseTeam':'ABCDEFGHIJ','SUPublicEDKey':base64.b64encode(bytes(32)).decode(),'SUFeedURL':'https://example.invalid/appcast.xml','SumidokuReleaseCatalogURL':'https://example.invalid/desktop-releases.json'}
        (self.app/'Contents/Resources/sumidoku-server').write_bytes(b'fixture-server');(self.app/'Contents/MacOS/Sumidoku').write_bytes(b'fixture-client')
        (self.app/'Contents/Resources/server-build.json').write_text(json.dumps({'variant':'fork','sha256':module.digest(self.app/'Contents/Resources/sumidoku-server'),'sourceRevision':'a'*40,'databaseSchemaVersion':37}))
        (self.app/'Contents/Resources/client-build.json').write_text(json.dumps({'sourceRevision':'a'*40,'dirty':False}))
        self.output=self.root/'Output';self.write()
    def tearDown(self):self.temp.cleanup()
    def write(self):(self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
    def prepare(self,previous=None):return module.prepare(self.app,self.output,self.root/'Sparkle',self.root/'TrustTool',previous)
    def test_beta_requires_prior_authenticated_stable_before_commands_or_output(self):
        with patch.object(module.subprocess,'run') as command:
            with self.assertRaisesRegex(ValueError,'Beta requires'):self.prepare()
            command.assert_not_called()
        self.assertFalse(self.output.exists())
    def test_development_build_rejected_even_with_flags_and_trust_fields(self):
        self.info['SumidokuDevelopmentBuild']=True;self.write()
        with patch.object(module.subprocess,'run') as command:
            with self.assertRaisesRegex(ValueError,'development builds'):self.prepare(self.root/'catalog.json')
            command.assert_not_called()
        self.assertFalse(self.output.exists())
    def test_unsafe_feed_rejected_before_codesign(self):
        for url in ['http://example.invalid/feed','https://owner:secret@example.invalid/feed','https://example.invalid/feed?token=x','https://example.invalid:8443/feed']:
            self.info['SUFeedURL']=url;self.write()
            with patch.object(module.subprocess,'run') as command:
                with self.assertRaises(ValueError):self.prepare(self.root/'catalog.json')
                command.assert_not_called()
    def test_unknown_stable_provenance_rejected_despite_other_provisioning(self):
        self.info['SumidokuReleaseVersion']='1.3.0';self.write()
        with patch.object(module.subprocess,'run'):
            with self.assertRaisesRegex(ValueError,'provenance is not qualified'):self.prepare()
        self.assertFalse(self.output.exists())
    def test_beta_rejects_dirty_or_mixed_source_artifacts(self):
        for proof in [{'sourceRevision':'a'*40,'dirty':True},{'sourceRevision':'b'*40,'dirty':False}]:
            (self.app/'Contents/Resources/client-build.json').write_text(json.dumps(proof))
            with patch.object(module.subprocess,'run'):
                with self.assertRaisesRegex(ValueError,'clean, exact-source'):self.prepare(self.root/'catalog.json')
            self.assertFalse(self.output.exists())
    def test_existing_output_is_preserved(self):
        self.output.mkdir();sentinel=self.output/'keep';sentinel.write_bytes(b'previous-artifact')
        with patch.object(module.subprocess,'run'):
            with self.assertRaisesRegex(ValueError,'Output exists'):self.prepare(self.root/'catalog.json')
        self.assertEqual(sentinel.read_bytes(),b'previous-artifact')
    def test_community_policy_uses_publisher_seal_without_apple_credentials(self):
        self.info['SumidokuDistributionMode']='community';self.info.pop('SumidokuReleaseTeam');self.write()
        with patch.object(module.subprocess,'run') as command:
            # Stop at the intentionally unqualified Stable gate after checking trust commands.
            self.info['SumidokuReleaseVersion']='1.3.0+community.1';self.write()
            with self.assertRaisesRegex(ValueError,'provenance is not qualified'):self.prepare()
            calls=[call.args[0] for call in command.call_args_list]
        self.assertTrue(any(str(c[0]).endswith('TrustTool') and c[1]=='bundle' for c in calls))
        self.assertFalse(any(c[0] in ['spctl','xcrun'] for c in calls))
        self.assertFalse(any('-R' in c for c in calls))
    def test_unknown_policy_and_fixture_bundle_cannot_be_distributed(self):
        for extra in [{'SumidokuDistributionMode':'unsigned'},{'SumidokuDistributionMode':'community','SumidokuEndToEndFixture':True}]:
            self.info.update(extra);self.write()
            with patch.object(module.subprocess,'run') as command:
                with self.assertRaises(ValueError):self.prepare(self.root/'catalog.json')
                command.assert_not_called()
    def test_tag_versions_cannot_inject_paths_or_server_tags(self):
        for value in ['v1.3.0','desktop-v1.3.0','1.3.1-beta.0','1.3.1-beta.1/../../other','1.3.1-rc.1','1.3.0\n']:
            with self.assertRaises(ValueError):module.release_version(value)
        self.assertEqual(module.release_version('1.3.1-beta.1'),'1.3.1-beta.1')
        self.assertEqual(module.release_version('1.3.0+community.1'),'1.3.0+community.1')

if __name__=='__main__':unittest.main()
