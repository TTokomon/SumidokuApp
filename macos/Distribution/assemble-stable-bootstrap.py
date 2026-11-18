#!/usr/bin/env python3
"""Overlay updater code on a separate audited Stable worktree; never relabel the Beta UI."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

BASE='9fd09f5c1e5c01f2061d6a00945867e62108c3a4'
OVERLAY=['AppUpdates.swift','UpdatePolicy.swift','ReleaseTrust.swift','ArchiveValidation.swift','PairedInstallation.swift','UpdateHandoff.swift','NativeUpdateInstaller.swift','CommunityBundleTrust.swift','ReleaseIdentity.swift','InstallationContext.swift','CommunityEndToEnd.swift','CommunityEndToEndDownload.swift','WebSession.swift']

def assemble(source,target):
    if source.resolve()==target.resolve():raise ValueError('A separate Stable worktree is required')
    if subprocess.check_output(['git','rev-parse','HEAD'],cwd=target,text=True).strip()!=BASE:raise ValueError('Stable base is not the audited revision')
    if subprocess.check_output(['git','status','--porcelain'],cwd=target):raise ValueError('Stable worktree contains changes; preserve them')
    for name in OVERLAY:shutil.copy2(source/'macos/App'/name,target/'macos/App'/name)
    # Keep the Stable controller/UI outside updater hooks. MainWindow carries the
    # handoff and acknowledgement; the shell, logo, preference forms and web UI remain Stable.
    current=(source/'macos/App/SumidokuApp.swift').read_text()
    original=(target/'macos/App/SumidokuApp.swift').read_text()
    begin=current.index('struct MainWindow: View {');end=current.index('\nstruct WelcomeView:',begin)
    old_begin=original.index('struct MainWindow: View {');old_end=original.index('\nstruct WelcomeView:',old_begin)
    original=original[:old_begin]+current[begin:end]+original[old_end:]
    original=original.replace('let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sumidoku/bin")','let support = InstallationContext.home.appendingPathComponent("Library/Application Support/Sumidoku/bin")').replace('LibraryManager(binary: support','LibraryManager(home:InstallationContext.home,binary: support').replace('service: LaunchAgentService(helper: helper))','service: LaunchAgentService(helper: helper),port:InstallationContext.port)')
    original=original.replace('process.arguments = [helper.path, action]','process.arguments = [helper.path, action]+InstallationContext.serviceArguments').replace('process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path','process.environment = ["HOME": InstallationContext.home.path')
    (target/'macos/App/SumidokuApp.swift').write_text(original)
    # Library manager changes are restricted to the fixed production/test service scope.
    shutil.copy2(source/'macos/App/LibraryManager.swift',target/'macos/App/LibraryManager.swift')
    for name in ['build-app.sh','service.sh']:
        shutil.copy2(source/'macos'/name,target/'macos'/name)
    shutil.copytree(source/'macos/Distribution',target/'macos/Distribution',dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
    receipt={'stableBaseRevision':BASE,'updaterRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip(),'description':'Audited Stable shell and frontend with explicit updater-only overlay; distinct +community.1 version, not the original installed build','overlaySha256':{str(p.relative_to(target)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((target/'macos').rglob('*')) if p.is_file() and '__pycache__' not in p.parts}}
    (target/'stable-bootstrap-provenance.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('Assembled Stable bootstrap; unchanged Stable frontend and DesktopShell')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('target',type=Path);args=parser.parse_args();assemble(Path(__file__).resolve().parents[2],args.target)
