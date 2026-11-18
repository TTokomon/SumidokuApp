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
from unittest.mock import patch

BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
import common
spec=importlib.util.spec_from_file_location('recovery_writer',BASE/'publish.py')
writer=importlib.util.module_from_spec(spec);spec.loader.exec_module(writer)
VERSION='1.3.0+community.1'


class Remote:
    def __init__(self,root,plan,prior):
        self.root=root;self.plan=plan;self.calls=[];self.fault=None;self.corrupt=None
        self.releases={plan['tag']:{'tag_name':plan['tag'],'target_commitish':plan['sourceRevision'],'prerelease':False,'draft':True,'assets':[self.asset(n) for n in plan['files']]}}
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
        operation=(action,tag,name);self.calls.append(operation)
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
        elif action=='edit':
            assert '--draft=false' in args
            if tag==self.plan['tag'] and not self.plan['priorFeed']:
                feed=self.releases['desktop-updates']
                assert {a['name'] for a in feed['assets']}==set(writer.FEED_FILES),'First feed must be fully staged before exposing the app'
            self.releases[tag]['draft']=False
        else:raise AssertionError('Unexpected command')
        self.fail(operation,'after')


class RecoveryTests(unittest.TestCase):
    @contextmanager
    def transaction(self,existing_feed=False):
        with tempfile.TemporaryDirectory() as directory,ExitStack() as stack:
            root=Path(directory);entry=copy.deepcopy(common.selected(VERSION))
            for name in common.filenames(VERSION):(root/name).write_bytes(('qualified-fixture-'+name).encode())
            files={n:common.sha(root/n) for n in common.filenames(VERSION)}
            archive='Sumidoku-Desktop-'+VERSION+'-macOS-arm64.zip'
            entry.update(sha256=files[archive],length=(root/archive).stat().st_size)
            prior={n:hashlib.sha256(('old-'+n).encode()).hexdigest() for n in writer.FEED_FILES} if existing_feed else None
            plan={'format':1,'repository':common.REPO,'onlineChecks':True,'toolingCommit':common.policy()['toolingCommit'],'version':VERSION,'tag':'desktop-v'+VERSION,'sourceRevision':entry['sourceRevision'],'prerelease':False,'files':files,'priorFeed':prior}
            (root/'verified.json').write_text(json.dumps(plan))
            remote=Remote(root,plan,prior)
            stack.enter_context(patch.object(common,'selected',return_value=entry))
            stack.enter_context(patch.object(common,'maybe_release',side_effect=remote.lookup))
            stack.enter_context(patch.object(writer,'write',side_effect=remote.write))
            stack.enter_context(patch.object(writer.subprocess,'run',side_effect=AssertionError('Real processes forbidden in recovery tests')))
            stack.enter_context(patch.dict(os.environ,{'GITHUB_ACTIONS':'true','GITHUB_REPOSITORY':common.REPO,'GITHUB_REF':'refs/heads/main','GITHUB_WORKFLOW_REF':common.REPO+'/.github/workflows/desktop-publish.yml@refs/heads/main'}))
            yield root,plan,remote

    def assert_complete_and_idempotent(self,root,plan,remote,original_assets):
        try:writer.publish(root)
        except ValueError as error:self.fail('Authenticated transaction could not be resumed: '+str(error))
        self.assertFalse(remote.releases[plan['tag']]['draft'])
        self.assertFalse(remote.releases['desktop-updates']['draft'])
        self.assertEqual(remote.releases[plan['tag']]['assets'],original_assets)
        self.assertEqual({a['name']:a for a in remote.releases['desktop-updates']['assets']},{n:remote.asset(n) for n in writer.FEED_FILES})
        count=len(remote.calls);writer.publish(root)
        self.assertEqual(len(remote.calls),count,'Completed retry must perform no writes')

    def test_first_release_recovers_before_and_after_every_commit(self):
        operations=[('create','desktop-updates',''),*[('upload','desktop-updates',n) for n in writer.FEED_FILES],('edit','desktop-v'+VERSION,''),('edit','desktop-updates','')]
        for operation in operations:
            for phase in ['before','after']:
                with self.subTest(operation=operation,phase=phase),self.transaction() as (root,plan,remote):
                    original=copy.deepcopy(remote.releases[plan['tag']]['assets']);remote.fault=(operation,phase)
                    with self.assertRaisesRegex(RuntimeError,'Injected'):writer.publish(root)
                    if remote.releases[plan['tag']]['draft'] is False:
                        self.assertEqual(len(remote.releases['desktop-updates']['assets']),3)
                    self.assert_complete_and_idempotent(root,plan,remote,original)

    def test_existing_feed_recovers_each_upload_and_interrupted_clobber(self):
        operations=[('edit','desktop-v'+VERSION,''),*[('upload','desktop-updates',n) for n in writer.FEED_FILES]]
        for operation in operations:
            phases=['before','after','deleted'] if operation[0]=='upload' else ['before','after']
            for phase in phases:
                with self.subTest(operation=operation,phase=phase),self.transaction(True) as (root,plan,remote):
                    original=copy.deepcopy(remote.releases[plan['tag']]['assets']);remote.fault=(operation,phase)
                    with self.assertRaisesRegex(RuntimeError,'Injected'):writer.publish(root)
                    self.assert_complete_and_idempotent(root,plan,remote,original)

    def test_completes_legacy_public_app_with_absent_or_partial_feed(self):
        for count in [None,0,1,2,3]:
            with self.subTest(feed_assets=count),self.transaction() as (root,plan,remote):
                remote.releases[plan['tag']]['draft']=False
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
                with self.assertRaises(ValueError):writer.publish(root)
                self.assertEqual(remote.calls,[])

    def test_foreign_feed_digest_is_not_repaired(self):
        for prior in [False,True]:
            with self.subTest(prior=prior),self.transaction(prior) as (root,plan,remote):
                remote.releases[plan['tag']]['draft']=False
                remote.releases['desktop-updates']={'tag_name':'desktop-updates','target_commitish':plan['sourceRevision'],'draft':False,'assets':[{'name':writer.FEED_FILES[0],'digest':'sha256:'+'f'*64,'size':4}]}
                with self.assertRaises(ValueError):writer.publish(root)
                self.assertEqual(remote.calls,[])

    def test_corrupt_feed_upload_never_exposes_first_application(self):
        for name in writer.FEED_FILES:
            with self.subTest(asset=name),self.transaction() as (root,plan,remote):
                remote.corrupt=('upload','desktop-updates',name)
                with self.assertRaises(ValueError):writer.publish(root)
                self.assertTrue(remote.releases[plan['tag']]['draft'])
                count=len(remote.calls)
                with self.assertRaises(ValueError):writer.publish(root)
                self.assertEqual(len(remote.calls),count,'Foreign bytes require review, never automatic replacement')

    def test_missing_draft_or_incomplete_staging_never_writes(self):
        for state in ['missing','incomplete']:
            with self.subTest(state=state),self.transaction() as (root,plan,remote):
                if state=='missing':del remote.releases[plan['tag']]
                else:remote.releases[plan['tag']]['assets'].pop()
                with self.assertRaisesRegex(ValueError,'Stage the complete'):writer.publish(root)
                self.assertEqual(remote.calls,[])

    def test_forged_archive_receipt_cannot_change_approved_archive(self):
        with self.transaction() as (root,plan,remote):
            name='Sumidoku-Desktop-'+VERSION+'-macOS-arm64.zip'
            (root/name).write_bytes(b'forged archive')
            plan['files'][name]=common.sha(root/name)
            (root/'verified.json').write_text(json.dumps(plan))
            with self.assertRaisesRegex(ValueError,'reviewed approved'):writer.publish(root)
            self.assertEqual(remote.calls,[])

    def test_retry_does_not_bypass_branch_or_receipt_guards(self):
        with self.transaction() as (root,plan,remote):
            remote.releases[plan['tag']]['draft']=False
            with patch.dict(os.environ,{'GITHUB_REF':'refs/heads/feature'}):
                with self.assertRaisesRegex(ValueError,'main workflow'):writer.publish(root)
            plan['onlineChecks']=False;(root/'verified.json').write_text(json.dumps(plan))
            with self.assertRaisesRegex(ValueError,'Untrusted'):writer.publish(root)
            self.assertEqual(remote.calls,[])


if __name__=='__main__':unittest.main()
