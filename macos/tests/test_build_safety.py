"""Exercise the real scripts with disposable command fixtures; no compiler or server starts."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
class BuildSafetyTests(unittest.TestCase):
    def test_production_flags_work_in_system_bash_without_fixture_flags(self):
        script=(ROOT/'macos/build-app.sh').read_text()
        block=script[script.index('SWIFT_FLAGS='):script.index('APP_SOURCES=')]
        result=subprocess.run(['/bin/bash','-uc',block+'\nprintf "%s\\n" "${SWIFT_FLAGS[@]}"'],env={k:v for k,v in os.environ.items() if k!='SUMIDOKU_E2E_ROOT'},capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout.splitlines(),['-swift-version','5'])
    def test_build_rejects_production_signing_seed_before_starting_tools(self):
        for name in ['build-app.sh','build-fork.sh']:
            env=os.environ.copy();env['SUMIDOKU_SPARKLE_PRIVATE_KEY']='disposable-test-value';env.pop('SUMIDOKU_E2E_ROOT',None)
            result=subprocess.run(['/bin/bash',str(ROOT/'macos'/name)],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,2);self.assertIn('out of build processes',result.stderr)
    def test_missing_native_bundle_cannot_write_success_receipt(self):
        with tempfile.TemporaryDirectory(prefix='sumidoku-build-guard-') as temporary:
            root=Path(temporary);(root/'macos').mkdir();(root/'webui').mkdir();migrations=root/'crates/server/migrations';migrations.mkdir(parents=True);(migrations/'0001_init.sql').write_text('-- fixture')
            shutil.copy2(ROOT/'macos/build-fork.sh',root/'macos/build-fork.sh')
            child=root/'macos/build-app.sh';child.write_text('#!/bin/bash\nexit 0\n');child.chmod(0o700)
            commands=root/'commands';commands.mkdir()
            for name in ['npm','cargo']:
                p=commands/name;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o700)
            target=root/'target/release';target.mkdir(parents=True);(target/'sumidoku-server').write_bytes(b'fixture only')
            subprocess.run(['git','init','-q',str(root)],check=True)
            subprocess.run(['git','-C',str(root),'add','.'],check=True)
            subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture'],check=True)
            env=os.environ.copy();env.pop('SUMIDOKU_SPARKLE_PRIVATE_KEY',None);env['PATH']=str(commands)+os.pathsep+env['PATH'];env['CARGO_TARGET_DIR']=str(root/'target')
            result=subprocess.run(['/bin/bash',str(root/'macos/build-fork.sh')],env=env,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0);self.assertFalse((root/'dist/fork/native-build.json').exists());self.assertNotIn('Fork and native client built',result.stdout)

if __name__=='__main__':unittest.main()
