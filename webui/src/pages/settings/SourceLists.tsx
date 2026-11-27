import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Button, Switch } from '../../components';
import { api } from '../../api/client';
import { qk, useRefreshSourceRepo, useSourceRepos, useUpdateAllSources } from '../../api/hooks';
import type { SourceRefreshPreferences } from '../../api/types';
import ReposPanel from '../browse/ReposPanel';
import { AddRepoModal } from '../browse/AddRepoModal';

export function SourceLists() {
	const [bootstrap, setBootstrap] = useState(() => (typeof window === 'undefined' ? undefined : (window as Window & { __sumidokuCommunityStatus?: string }).__sumidokuCommunityStatus));
	useEffect(() => {
		const changed = (event: Event) => setBootstrap((event as CustomEvent<string>).detail);
		window.addEventListener('sumidoku:source-lists', changed);
		return () => window.removeEventListener('sumidoku:source-lists', changed);
	}, []);
	const [adding, setAdding] = useState(false);
	const [message, setMessage] = useState('');
	const [checking, setChecking] = useState(false);
	const client = useQueryClient();
	const repos = useSourceRepos();
	const refresh = useRefreshSourceRepo();
	const updateAll = useUpdateAllSources();
	async function checkUpdates() {
		setChecking(true);
		let failures = 0;
		try {
			for (const repo of repos.data ?? []) {
				try { await refresh.mutateAsync(repo.id); } catch { failures += 1; }
			}
			setMessage(failures ? `${failures} source list refresh failed. Cached sources remain available.` : 'Source lists refreshed. Available package updates are shown below.');
			void client.invalidateQueries({ queryKey: qk.sources });
		} finally { setChecking(false); }
	}
	async function updateInstalledSources() {
		if (!window.confirm('Update installed source packages? Sources used by manga may require migration review. No chapters will be downloaded.')) return;
		try {
			const result = await updateAll.mutateAsync();
			setMessage([
				`Updated ${result.updated.length} sources.`,
				...result.failed.map((failure) => `${failure.key}: ${failure.reason}`),
				...result.migrationWarnings.map((warning) => `${warning.key}: ${warning.message}`),
				...(result.migrationRequired.length ? [`Manual migration review required: ${result.migrationRequired.join(', ')}`] : [])
			].join(' '));
		} catch { setMessage('Source updates failed. Review the errors and retry.'); }
	}

	return <section aria-label="Source Lists">
		<h2>Source Lists</h2>
		<p className="muted">Manage your subscribed Aidoku-compatible source lists here. Built-in connections do not need a source list. Installed packages and repository subscriptions are separate.</p>
		{bootstrap === 'deferred' && <p role="status">Aidoku Community setup is deferred while its list is unavailable. The desktop will retry; your existing library remains usable.</p>}
		<section className="card settings-section" aria-label="Manual source updates">
			<h3>Manual source updates</h3>
			<div className="settings-actions">
				<Button disabled={repos.isPending || !repos.data?.length || checking} onClick={() => void checkUpdates()}>Check for Source Updates</Button>
				<Button disabled={updateAll.isPending} onClick={() => void updateInstalledSources()}>Update All Sources</Button>
			</div>
			{message && <p role="status">{message}</p>}
		</section>
		<Button variant="primary" onClick={() => setAdding(true)}>Add Source List</Button>
		<ReposPanel />
		<AddRepoModal open={adding} onClose={() => setAdding(false)} />
	</section>;
}

export function SourceAutomation() {
	const [confirmUpdates, setConfirmUpdates] = useState(false);
	const client = useQueryClient();
	const preferences = useQuery({
		queryKey: ['source-refresh-preferences'],
		queryFn: () => api<SourceRefreshPreferences>('/source-repos/preferences')
	});
	const save = useMutation({
		mutationFn: (body: SourceRefreshPreferences) => api<SourceRefreshPreferences>('/source-repos/preferences', { method: 'PUT', body }),
		onSuccess: (value) => { client.setQueryData(['source-refresh-preferences'], value); setConfirmUpdates(false); }
	});

	return <section className="card settings-section" aria-label="Source update preferences"><h2>Source Automation</h2>
			{preferences.isPending && <p role="status">Loading source update preferences…</p>}
			{preferences.isError && <p role="alert">Source update preferences could not be loaded. <Button onClick={() => void preferences.refetch()}>Retry</Button></p>}
			{preferences.data && <>
				<label className="settings-row"><span>Automatically refresh source lists</span><Switch label="Automatically refresh source lists" checked={preferences.data.autoRefreshLists} disabled={save.isPending} onChange={(value) => save.mutate({ ...preferences.data!, autoRefreshLists: value })} /></label>
				<label className="settings-row"><span>Automatically install source updates</span><Switch label="Automatically install source updates" checked={preferences.data.autoUpdatePackages} disabled={save.isPending} onChange={(value) => value ? setConfirmUpdates(true) : save.mutate({ ...preferences.data!, autoUpdatePackages: false })} /></label>
				<p className="muted">Automatic package updates apply only to enabled sources from their original list, with no registered manga and no breaking change. Sources used by saved manga require manual review. Chapters are never downloaded by these controls.</p>
				{confirmUpdates && <div role="group" aria-label="Confirm automatic source updates"><p>Allow eligible unused source packages to update automatically? Existing manga and reading progress will not be migrated unattended.</p><Button onClick={() => save.mutate({ ...preferences.data!, autoUpdatePackages: true })} disabled={save.isPending}>Enable automatic source updates</Button><Button onClick={() => setConfirmUpdates(false)}>Cancel</Button></div>}
			</>}
			{save.isError && <p role="alert">Preferences were not saved. Retry the change.</p>}

	</section>;
}
