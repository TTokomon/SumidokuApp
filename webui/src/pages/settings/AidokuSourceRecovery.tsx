import { useEffect, useRef, useState } from 'react';
import { aidokuSourceLabel, defaultRecoverySelection } from './aidokuRecovery';
import type { Dispatch, SetStateAction } from 'react';
import { useImportAidoku, useInstallRepoSource, useRepoSources, useSources } from '../../api/hooks';
import type { AidokuImportResponse } from '../../api/types';
import { Button, Modal } from '../../components';

export function missingAidokuIds(preview: AidokuImportResponse): string[] {
	return [...new Set([...(preview.missingSources ?? []), ...preview.skipped.filter((item) => item.reason === 'source not installed').map((item) => item.sourceKey)])].sort();
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
	const countBySource = new Map<string, number>();
	for (const entry of [...(preview.included ?? []), ...preview.skipped]) {
		if (ids.includes(entry.sourceKey)) countBySource.set(entry.sourceKey, (countBySource.get(entry.sourceKey) ?? 0) + 1);
	}
	const defaults = JSON.stringify(defaultRecoverySelection(matches));
	const previousDefaults = useRef<string[]>([]);
	useEffect(() => {
		const next = JSON.parse(defaults) as string[];
		const added = next.filter((key) => !previousDefaults.current.includes(key));
		previousDefaults.current = next;
		if (added.length) setSelected((old) => [...new Set([...old, ...added.filter((key) => !old.some((item) => item.slice(item.indexOf(':') + 1) === key.slice(key.indexOf(':') + 1)))])]);
	}, [defaults, setSelected]);
	const eligible = matches.filter((entry) => selected.includes(`${entry.repoId}:${entry.key}`) && entry.installedId === null);
	async function refreshPreview() {
		try { onPreview(await recheck.mutateAsync({ file, dryRun: true })); setError(''); } catch (error) { setError(error instanceof Error ? error.message : 'Backup preview could not be rechecked.'); }
	}
	async function installSelected() {
		setBusy(true); setError('');
		try {
			const failed: string[] = [];
			for (const item of eligible) {
				try { await install.mutateAsync({ repoId: item.repoId, sourceKey: item.key }); }
				catch { failed.push(aidokuSourceLabel(item.key)); }
			}
			await refreshPreview();
			setConfirm(false);
			if (failed.length) setError(`Could not install: ${failed.join(', ')}. You can retry these sources before importing.`);
		} catch (error) { setError(error instanceof Error ? error.message : 'Some sources could not be installed. Recheck and retry remaining sources.'); }
		finally { setBusy(false); }
	}
	return <section aria-label="Recover Missing Aidoku Sources">
		<h3>Restore your sources</h3>
		<p>Your backup contains manga from sources that are not installed. Install the available matches to read them again. Nothing is installed until you approve.</p>
		<details className="settings-backup__skipped"><summary>How source recovery works</summary><p>Sources must match the exact ID from your backup. Source names are never used to guess. Your original backup is unchanged.</p></details>
		{ids.length ? <ul>{ids.map((id) => <li key={id}><strong title={id}>{matches.find((entry) => entry.key === id)?.name ?? aidokuSourceLabel(id)}</strong> ({countBySource.get(id) ?? 0} records)
			{installed.data?.some((source) => source.key === id) ? ' — installed; recheck the backup' : !matches.some((entry) => entry.key === id) ? ' — unavailable in your source lists' : ' — available to install'}
		</li>)}</ul> : <p>No missing source IDs in this preview.</p>}
		{matches.filter((entry) => entry.installedId === null).map((entry) => <label className="repos__lang-row" key={`${entry.repoId}:${entry.key}`}>
			<input type="checkbox" checked={selected.includes(`${entry.repoId}:${entry.key}`)} onChange={(event) => { const checked = event.currentTarget.checked, key = `${entry.repoId}:${entry.key}`; setSelected((old) => checked ? [...old.filter((item) => !item.endsWith(`:${entry.key}`)), key] : old.filter((item) => item !== key)); }} />
			{entry.name || aidokuSourceLabel(entry.key)} · {entry.repoName ?? `List ${entry.repoId}`} · v{entry.version}
		</label>)}
		{packages.isError && <p role="alert">Source lists could not be loaded. Cached/offline lists remain managed in Source Lists.</p>}
		<div className="settings-actions">
			<Button onClick={onManageLists}>Add / Manage Source Lists…</Button>
			<Button disabled={!eligible.length || busy} onClick={() => setConfirm(true)}>Install {eligible.length} selected sources…</Button>
			<Button loading={recheck.isPending} disabled={busy} onClick={() => void refreshPreview()}>Recheck Backup</Button>
		</div>
		{preview.missingSources?.length ? <p className="muted">You can import now even if some sources are unavailable. Your saved library and supported reading progress and tracker bindings will be kept.</p> : <p className="muted">Install matching sources before importing to avoid skipping their entries.</p>}
		{error && <p role="alert">{error}</p>}
		<Modal open={confirm} title="Confirm Source Installation" onClose={() => setConfirm(false)} footer={<Button loading={busy} onClick={() => void installSelected()}>Install and Recheck Backup</Button>}>
			<p>Only the selected packages will be installed. Manga import still requires your separate confirmation after the new preview.</p>
			<ul>{matches.filter((entry) => selected.includes(`${entry.repoId}:${entry.key}`)).map((entry) => <li key={`${entry.repoId}:${entry.key}`}>{entry.name || aidokuSourceLabel(entry.key)} — {entry.repoName ?? entry.repoId}</li>)}</ul>
		</Modal>
	</section>;
}
