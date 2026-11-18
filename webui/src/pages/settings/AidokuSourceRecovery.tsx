import { useState } from 'react';
import type { Dispatch, SetStateAction } from 'react';
import { useImportAidoku, useInstallRepoSource, useRepoSources, useSources } from '../../api/hooks';
import type { AidokuImportResponse } from '../../api/types';
import { Button, Modal } from '../../components';

export function missingAidokuIds(preview: AidokuImportResponse): string[] {
	return [...new Set(preview.skipped.filter((item) => item.reason === 'source not installed').map((item) => item.sourceKey))].sort();
}

export function AidokuSourceRecovery({ file, preview, onPreview, onManageLists, selection, onSelectionChange }: {
	selection?: string[]; onSelectionChange?: Dispatch<SetStateAction<string[]>>;
	file: File; preview: AidokuImportResponse; onPreview: (value: AidokuImportResponse) => void; onManageLists: () => void;
}) {
	const ids = missingAidokuIds(preview);
	const packages = useRepoSources({ query: '' }); const installed = useSources();
	const install = useInstallRepoSource(); const recheck = useImportAidoku();
	const [localSelection, setLocalSelection] = useState<string[]>([]);
	const selected = selection ?? localSelection; const setSelected = onSelectionChange ?? setLocalSelection;
	const [confirm, setConfirm] = useState(false);
	const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
	const matches = (packages.data ?? []).filter((entry) => ids.includes(entry.key));
	async function refreshPreview() {
		try { onPreview(await recheck.mutateAsync({ file, dryRun: true })); setError(''); } catch (error) { setError(error instanceof Error ? error.message : 'Backup preview could not be rechecked.'); }
	}
	async function installSelected() {
		setBusy(true); setError('');
		try {
			for (const item of matches.filter((entry) => selected.includes(`${entry.repoId}:${entry.key}`) && entry.installedId === null)) await install.mutateAsync({ repoId: item.repoId, sourceKey: item.key });
			setSelected([]); setConfirm(false); await refreshPreview();
		} catch (error) { setError(error instanceof Error ? error.message : 'Some sources could not be installed. Recheck and retry remaining sources.'); }
		finally { setBusy(false); }
	}
	return <section aria-label="Recover Missing Aidoku Sources">
		<h3>Source recovery</h3>
		<p>Match exact source IDs only. Source names are never used to guess a mapping. Your original backup is unchanged.</p>
		{ids.length ? <ul>{ids.map((id) => <li key={id}><code>{id}</code>
			{installed.data?.some((source) => source.key === id) ? ' — installed; recheck the backup' : !matches.some((entry) => entry.key === id) ? ' — no matching package in your subscribed lists' : ' — matching list packages below'}
		</li>)}</ul> : <p>No missing source IDs in this preview.</p>}
		{matches.filter((entry) => entry.installedId === null).map((entry) => <label className="repos__lang-row" key={`${entry.repoId}:${entry.key}`}>
			<input type="checkbox" checked={selected.includes(`${entry.repoId}:${entry.key}`)} onChange={(event) => { const checked = event.currentTarget.checked, key = `${entry.repoId}:${entry.key}`; setSelected((old) => checked ? [...old.filter((item) => !item.endsWith(`:${entry.key}`)), key] : old.filter((item) => item !== key)); }} />
			{entry.key} · {entry.repoName ?? `List ${entry.repoId}`} · v{entry.version}
		</label>)}
		{packages.isError && <p role="alert">Source lists could not be loaded. Cached/offline lists remain managed in Source Lists.</p>}
		<div className="settings-actions">
			<Button onClick={onManageLists}>Add / Manage Source Lists…</Button>
			<Button disabled={!selected.length || busy} onClick={() => setConfirm(true)}>Install Selected Matching Sources…</Button>
			<Button loading={recheck.isPending} disabled={busy} onClick={() => void refreshPreview()}>Recheck Backup</Button>
		</div>
		<p className="muted">To add a GitHub list, open Source Lists, paste its repository/index URL, then return to Storage & Backups and resume this import. Recheck always previews the same original file.</p>
		{error && <p role="alert">{error}</p>}
		<Modal open={confirm} title="Confirm Source Installation" onClose={() => setConfirm(false)} footer={<Button loading={busy} onClick={() => void installSelected()}>Install and Recheck Backup</Button>}>
			<p>Only the selected packages will be installed. Manga import still requires your separate confirmation after the new preview.</p>
			<ul>{matches.filter((entry) => selected.includes(`${entry.repoId}:${entry.key}`)).map((entry) => <li key={`${entry.repoId}:${entry.key}`}>{entry.key} — {entry.repoName ?? entry.repoId}</li>)}</ul>
		</Modal>
	</section>;
}
