"""Offline stateful failure injection. Every GitHub read/write/process is mocked."""
import copy
from contextlib import contextmanager,ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
import common
spec=importlib.util.spec_from_file_location('recovery_writer',BASE/'publish.py')
writer=importlib.util.module_from_spec(spec);spec.loader.exec_module(writer)
VERSION='1.3.0+community.1'


class Remote:
    def __init__(self,root,plan,prior):
        self.root=root;self.plan=plan;self.calls=[];self.fault=None;self.corrupt=None
        self.releases={plan['tag']:{'tag_name':plan['tag'],'target_commitish':plan['sourceRevision'],'id':123,'prerelease':plan['prerelease'],'draft':True,'body':'Draft placeholder','assets':[self.asset(n) for n in plan['files']]}}
        if prior:
            self.releases['desktop-updates']={'tag_name':'desktop-updates','target_commitish':'previous-authenticated-source','prerelease':False,'draft':False,'assets':[{'name':n,'digest':'sha256:'+h,'size':100} for n,h in prior.items()]}

    def asset(self,name):return {'name':name,'digest':'sha256:'+self.plan['files'][name],'size':(self.root/name).stat().st_size}
    def lookup(self,tag):return copy.deepcopy(self.releases.get(tag))
    def fail(self,operation,phase):
        if self.fault==(operation,phase):
            self.fault=None
            raise RuntimeError('Injected remote failure '+repr((operation,phase)))
    def write(self,*args):
        assert args[0]=='release'
        action,tag=args[1:3];name=Path(args[3]).name if action=='upload' else ''
        operation=('notes' if action=='edit' and '--notes-file' in args else action,tag,name);self.calls.append(operation)
        if tag==self.plan['tag'] and action!='edit':raise AssertionError('Application asset mutation forbidden')
        self.fail(operation,'before')
        if action=='create':
            assert tag not in self.releases
            self.releases[tag]={'tag_name':tag,'target_commitish':args[args.index('--target')+1],'prerelease':False,'draft':'--draft' in args,'assets':[]}
        elif action=='upload':
            remote=self.releases[tag];old=[a for a in remote['assets'] if a['name']==name]
            if old:
                assert '--clobber' in args
                remote['assets']=[a for a in remote['assets'] if a['name']!=name]
                self.fail(operation,'deleted')
            remote['assets'].append(self.asset(name))
            if self.corrupt==operation:remote['assets'][-1]['digest']='sha256:'+'f'*64
        elif operation[0]=='notes':
            assert self.releases[tag]['draft'] and '--draft=false' not in args
            self.releases[tag]['body']=Path(args[args.index('--notes-file')+1]).read_bytes().decode()
        elif action=='edit':
            assert '--draft=false' in args
            if tag==self.plan['tag']:
                assert self.releases[tag]['body']==(self.root/'RELEASE_NOTES.md').read_text()
                assert '--prerelease='+str(self.plan['prerelease']).lower() in args
            if tag==self.plan['tag'] and not self.plan['priorFeed']:
                feed=self.releases['desktop-updates']
                assert {a['name'] for a in feed['assets']}==set(writer.FEED_FILES),'First feed must be fully staged before exposing the app'
            self.releases[tag]['draft']=False
        else:raise AssertionError('Unexpected command')
        self.fail(operation,'after')


class RecoveryTests(unittest.TestCase):
    @contextmanager
    def transaction(self,existing_feed=False,version=VERSION):
        with tempfile.TemporaryDirectory() as directory,ExitStack() as stack:
            root=Path(directory);entry=copy.deepcopy(common.selected(version))
            for name in common.filenames(version):(root/name).write_bytes(('qualified-fixture-'+name).encode())
            files={n:common.sha(root/n) for n in common.filenames(version)}
            archive='Sumidoku-Desktop-'+version+'-macOS-arm64.zip'
            entry.update(sha256=files[archive],length=(root/archive).stat().st_size)
            prior={n:hashlib.sha256(('old-'+n).encode()).hexdigest() for n in writer.FEED_FILES} if existing_feed else None
            run={'id':'321','head':'c'*40,'workflow':common.REPO+'/.github/workflows/desktop-publish.yml@refs/heads/main'}
            plan={'format':2,'repository':common.REPO,'onlineChecks':True,'toolingCommit':common.policy()['toolingCommit'],'policySha256':common.policy_digest(),'run':run,'releaseId':123,'version':version,'tag':'desktop-v'+version,'sourceRevision':entry['sourceRevision'],'prerelease':entry['channel']=='beta','files':files,'sizes':{name:(root/name).stat().st_size for name in files},'priorFeed':prior}
            (root/'verified.json').write_text(json.dumps(plan))
            remote=Remote(root,plan,prior)
            stack.enter_context(patch.object(common,'selected',return_value=entry))
            stack.enter_context(patch.object(common,'maybe_release',side_effect=remote.lookup))
            stack.enter_context(patch.object(writer,'write',side_effect=remote.write))
            stack.enter_context(patch.object(writer.subprocess,'run',side_effect=AssertionError('Real processes forbidden in recovery tests')))
            stack.enter_context(patch.dict(os.environ,{'GITHUB_RUN_ID':run['id'],'GITHUB_SHA':run['head'],'DESKTOP_VERSION':version,'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':common.REPO,'GITHUB_REF':'refs/heads/main','GITHUB_WORKFLOW_REF':common.REPO+'/.github/workflows/desktop-publish.yml@refs/heads/main'}))
            yield root,plan,remote

    def publish(self,root):
        writer.publish(root,writer.read_receipt(root/'verified.json'))

    def assert_complete_and_idempotent(self,root,plan,remote,original_assets):
        try:self.publish(root)
        except ValueError as error:self.fail('Authenticated transaction could not be resumed: '+str(error))
        self.assertFalse(remote.releases[plan['tag']]['draft'])
        self.assertFalse(remote.releases['desktop-updates']['draft'])
        self.assertEqual(remote.releases[plan['tag']]['assets'],original_assets)
        self.assertEqual({a['name']:a for a in remote.releases['desktop-updates']['assets']},{n:remote.asset(n) for n in writer.FEED_FILES})
        count=len(remote.calls);self.publish(root)
        self.assertEqual(len(remote.calls),count,'Completed retry must perform no writes')

    def test_first_release_recovers_before_and_after_every_commit(self):
        operations=[('notes','desktop-v'+VERSION,''),('create','desktop-updates',''),*[('upload','desktop-updates',n) for n in writer.FEED_FILES],('edit','desktop-v'+VERSION,''),('edit','desktop-updates','')]
        for operation in operations:
            for phase in ['before','after']:
                with self.subTest(operation=operation,phase=phase),self.transaction() as (root,plan,remote):
                    original=copy.deepcopy(remote.releases[plan['tag']]['assets']);remote.fault=(operation,phase)
                    with self.assertRaisesRegex(RuntimeError,'Injected'):self.publish(root)
                    if remote.releases[plan['tag']]['draft'] is False:
                        self.assertEqual(len(remote.releases['desktop-updates']['assets']),3)
                    self.assert_complete_and_idempotent(root,plan,remote,original)

    def test_existing_feed_recovers_each_upload_and_interrupted_clobber(self):
        version='1.3.1-beta.1'
        operations=[('notes','desktop-v'+version,''),('edit','desktop-v'+version,''),*[('upload','desktop-updates',n) for n in writer.FEED_FILES]]
        for operation in operations:
            phases=['before','after','deleted'] if operation[0]=='upload' else ['before','after']
            for phase in phases:
                with self.subTest(operation=operation,phase=phase),self.transaction(True,version) as (root,plan,remote):
                    original=copy.deepcopy(remote.releases[plan['tag']]['assets']);remote.fault=(operation,phase)
                    with self.assertRaisesRegex(RuntimeError,'Injected'):self.publish(root)
                    self.assert_complete_and_idempotent(root,plan,remote,original)

    def test_completes_legacy_public_app_with_absent_or_partial_feed(self):
        for count in [None,0,1,2,3]:
            with self.subTest(feed_assets=count),self.transaction() as (root,plan,remote):
                remote.releases[plan['tag']]['draft']=False
                remote.releases[plan['tag']]['body']=(root/'RELEASE_NOTES.md').read_text()
                if count is not None:
                    remote.releases['desktop-updates']={'tag_name':'desktop-updates','target_commitish':plan['sourceRevision'],'draft':False,'assets':[remote.asset(n) for n in writer.FEED_FILES[:count]]}
                self.assert_complete_and_idempotent(root,plan,remote,copy.deepcopy(remote.releases[plan['tag']]['assets']))

    def test_tampered_public_application_is_refused_without_writes(self):
        for mutation in ['digest','size','missing','extra','source','channel']:
            with self.subTest(mutation=mutation),self.transaction() as (root,plan,remote):
                app=remote.releases[plan['tag']];app['draft']=False
                if mutation=='digest':app['assets'][0]['digest']='sha256:'+'f'*64
                if mutation=='size':app['assets'][0]['size']+=1
                if mutation=='missing':app['assets'].pop()
                if mutation=='extra':app['assets'].append({'name':'unexpected'})
                if mutation=='source':app['target_commitish']='foreign-source'
                if mutation=='channel':app['prerelease']=True
                with self.assertRaises(ValueError):self.publish(root)
                self.assertEqual(remote.calls,[])

    def test_foreign_feed_digest_is_not_repaired(self):
        for prior in [False,True]:
            with self.subTest(prior=prior),self.transaction(prior) as (root,plan,remote):
                remote.releases[plan['tag']]['draft']=False
                remote.releases['desktop-updates']={'tag_name':'desktop-updates','target_commitish':plan['sourceRevision'],'draft':False,'assets':[{'name':writer.FEED_FILES[0],'digest':'sha256:'+'f'*64,'size':4}]}
                with self.assertRaises(ValueError):self.publish(root)
                self.assertEqual(remote.calls,[])

    def test_corrupt_feed_upload_never_exposes_first_application(self):
        for name in writer.FEED_FILES:
            with self.subTest(asset=name),self.transaction() as (root,plan,remote):
                remote.corrupt=('upload','desktop-updates',name)
                with self.assertRaises(ValueError):self.publish(root)
                self.assertTrue(remote.releases[plan['tag']]['draft'])
                count=len(remote.calls)
                with self.assertRaises(ValueError):self.publish(root)
                self.assertEqual(len(remote.calls),count,'Foreign bytes require review, never automatic replacement')

    def test_missing_draft_or_incomplete_staging_never_writes(self):
        for state in ['missing','incomplete']:
            with self.subTest(state=state),self.transaction() as (root,plan,remote):
                if state=='missing':del remote.releases[plan['tag']]
                else:remote.releases[plan['tag']]['assets'].pop()
                with self.assertRaisesRegex(ValueError,'Stage the complete'):self.publish(root)
                self.assertEqual(remote.calls,[])

    def test_forged_archive_receipt_cannot_change_approved_archive(self):
        with self.transaction() as (root,plan,remote):
            name='Sumidoku-Desktop-'+VERSION+'-macOS-arm64.zip'
            (root/name).write_bytes(b'forged archive')
            plan['files'][name]=common.sha(root/name)
            (root/'verified.json').write_text(json.dumps(plan))
            with self.assertRaisesRegex(ValueError,'reviewed approved'):self.publish(root)
            self.assertEqual(remote.calls,[])

    def test_receipt_rejects_other_run_policy_and_source(self):
        with self.transaction() as (root,plan,remote):
            receipt=root/'verified.json'
            for field,value in [('onlineChecks',False),('run',{**plan['run'],'id':'999'}),('policySha256','0'*64),('sourceRevision','0'*40),('files',{}),('sizes',{})]:
                with self.subTest(field=field):
                    receipt.write_text(json.dumps({**plan,field:value}))
                    with self.assertRaises(ValueError):writer.read_receipt(receipt)
            receipt.unlink()
            with self.assertRaisesRegex(ValueError,'Missing'):writer.read_receipt(receipt)
            self.assertEqual(remote.calls,[])

    def test_artifact_origin_and_receipt_only_zip(self):
        with self.transaction() as (root,plan,_):
            metadata={'workflow_run':{'id':321,'head_sha':plan['run']['head']},'name':common.RECEIPT_ARTIFACT,'expired':False}
            target=root/'downloaded.json'

            def download(endpoint,path,limit):
                self.assertEqual(limit,2*common.RECEIPT_LIMIT)
                with zipfile.ZipFile(path,'w') as package:
                    package.writestr(common.RECEIPT_NAME,json.dumps(plan))
                    if extra:package.writestr('unpublished.zip',b'never accepted')

            with patch.object(common,'gh_json',return_value=metadata),patch.object(common,'download_stream',side_effect=download) as fetch:
                metadata['workflow_run']['id']=999
                with self.assertRaisesRegex(ValueError,'workflow run'):writer.fetch_receipt('123',target)
                fetch.assert_not_called()
                metadata['workflow_run']['id']=321
                extra=True
                with self.assertRaisesRegex(ValueError,'receipt-only'):writer.fetch_receipt('123',target)
                self.assertFalse(target.exists())
                extra=False
                writer.fetch_receipt('123',target)
                self.assertEqual(writer.read_receipt(target),plan)

    def test_protected_draft_download_rejects_bad_metadata_bytes_and_authentication(self):
        for failure in ['missing','digest','identity','auth','changed bytes','bad signature']:
            with self.subTest(failure=failure),self.transaction() as (root,plan,remote),tempfile.TemporaryDirectory() as directory:
                asset=remote.releases[plan['tag']]['assets'][0]
                if failure=='missing':remote.releases[plan['tag']]['assets'].pop()
                if failure=='digest':asset['digest']='sha256:'+'a'*64
                if failure=='identity':remote.releases[plan['tag']]['id']=555

                def download(item,destination,limit):
                    if failure=='auth':raise RuntimeError('GitHub draft download denied')
                    destination.write_bytes(b'bad data' if failure=='changed bytes' else (root/item['name']).read_bytes())

                with patch.object(common,'download_asset',side_effect=download),patch.object(writer.validate,'verify',side_effect=ValueError('Signature mismatch')) as verify:
                    with self.assertRaises((ValueError,RuntimeError)):
                        writer.authenticate_downloads(plan,Path(directory),root)
                    self.assertEqual(verify.called,failure=='bad signature')
                self.assertEqual(remote.calls,[])

    def test_protected_verifier_receives_bytes_without_release_credential(self):
        with self.transaction() as (root,plan,remote),tempfile.TemporaryDirectory() as directory:
            (root/'desktop-releases.json').write_text(json.dumps({'releases':[]}))
            digest=common.sha(root/'desktop-releases.json')
            name='desktop-releases.json'
            plan['files'][name]=digest
            plan['sizes'][name]=(root/name).stat().st_size
            remote.releases[plan['tag']]['assets']=[remote.asset(n) for n in plan['files']]

            def download(item,destination,limit):
                self.assertEqual(os.environ.get('GH_TOKEN'),'test-only')
                destination.write_bytes((root/item['name']).read_bytes())

            def verify(*args):
                self.assertNotIn('GH_TOKEN',os.environ)
                self.assertNotIn('GITHUB_TOKEN',os.environ)

            with patch.dict(os.environ,{'GH_TOKEN':'test-only','GITHUB_TOKEN':'other-test-only'}),patch.object(common,'download_asset',side_effect=download),patch.object(writer.validate,'verify',side_effect=verify) as verifier:
                writer.authenticate_downloads(plan,Path(directory),root)
                verifier.assert_called_once()
                self.assertEqual(os.environ.get('GH_TOKEN'),'test-only')
            self.assertEqual(remote.calls,[])

    def test_modified_notes_are_refused_before_any_write(self):
        with self.transaction() as (root,plan,remote):
            (root/'RELEASE_NOTES.md').write_text('Forged text')
            with self.assertRaisesRegex(ValueError,'notes do not match'):
                self.publish(root)
            self.assertEqual(remote.calls,[])

    def test_public_wrong_body_is_not_repaired(self):
        with self.transaction() as (root,plan,remote):
            remote.releases[plan['tag']]['draft']=False
            with self.assertRaisesRegex(ValueError,'body differs'):
                self.publish(root)
            self.assertEqual(remote.calls,[])

    def test_retry_does_not_bypass_branch_or_receipt_guards(self):
        with self.transaction() as (root,plan,remote):
            remote.releases[plan['tag']]['draft']=False
            with patch.dict(os.environ,{'GITHUB_REF':'refs/heads/feature'}):
                with self.assertRaisesRegex(ValueError,'main workflow'):self.publish(root)
            plan['onlineChecks']=False;(root/'verified.json').write_text(json.dumps(plan))
            with self.assertRaisesRegex(ValueError,'Untrusted'):self.publish(root)
            self.assertEqual(remote.calls,[])


if __name__=='__main__':unittest.main()
