import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { aidokuSourceLabel, defaultRecoverySelection } from './aidokuRecovery';
import type { Dispatch, RefObject, SetStateAction } from 'react';
import { useImportAidoku, useInstallRepoSource, useRepoSources, useSources } from '../../api/hooks';
import type { AidokuImportResponse } from '../../api/types';
import { Button } from '../../components';

export function missingAidokuIds(preview: AidokuImportResponse): string[] {
	return [...new Set([...(preview.missingSources ?? []), ...preview.skipped.filter((item) => item.reason === 'source not installed').map((item) => item.sourceKey)])].sort();
}

export function AidokuSourceRecovery({ file, preview, onPreview, onManageLists, selection, onSelectionChange, onBusyChange, seenDefaults, onPreviewInvalidated }: {
	seenDefaults?: RefObject<Set<string>>; onPreviewInvalidated?: () => void;
	selection?: string[]; onSelectionChange?: Dispatch<SetStateAction<string[]>>; onBusyChange?: (busy: boolean) => void;
	file: File; preview: AidokuImportResponse; onPreview: (value: AidokuImportResponse) => void; onManageLists: () => void;
}) {
	const { t } = useTranslation();
	const ids = missingAidokuIds(preview);
	const packages = useRepoSources({ query: '' }); const installed = useSources();
	const install = useInstallRepoSource(); const recheck = useImportAidoku();
	const [localSelection, setLocalSelection] = useState<string[]>([]);
	const selected = selection ?? localSelection; const setSelected = onSelectionChange ?? setLocalSelection;
	const [confirm, setConfirm] = useState(false);
	const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
	useEffect(() => { onBusyChange?.(busy || confirm || recheck.isPending); return () => onBusyChange?.(false); }, [busy, confirm, recheck.isPending, onBusyChange]);
	const matches = (packages.data ?? []).filter((entry) => ids.includes(entry.key));
	const countBySource = new Map<string, number>();
	for (const entry of [...(preview.included ?? []), ...preview.skipped]) {
		if (ids.includes(entry.sourceKey)) countBySource.set(entry.sourceKey, (countBySource.get(entry.sourceKey) ?? 0) + 1);
	}
	const defaults = JSON.stringify(defaultRecoverySelection(matches));
	const localDefaults = useRef(new Set<string>());
	const previousDefaults = seenDefaults ?? localDefaults;
	useEffect(() => {
		const next = JSON.parse(defaults) as string[];
		const added = next.filter((key) => !previousDefaults.current.has(key));
		for (const key of added) previousDefaults.current.add(key);
		if (added.length) setSelected((old) => [...new Set([...old, ...added.filter((key) => !old.some((item) => item.slice(item.indexOf(':') + 1) === key.slice(key.indexOf(':') + 1)))])]);
	}, [defaults, setSelected, previousDefaults]);
	const eligible = matches.filter((entry) => selected.includes(`${entry.repoId}:${entry.key}`) && entry.installedId === null);
	async function refreshPreview() {
		onPreviewInvalidated?.();
		try { onPreview(await recheck.mutateAsync({ file, dryRun: true })); setError(''); } catch (error) { setError(error instanceof Error ? error.message : t('aidokuWizard.recheckError')); }
	}
	async function installSelected() {
		setBusy(true); setError('');
		onPreviewInvalidated?.();
		try {
			const failed: string[] = [];
			for (const item of eligible) {
				try { await install.mutateAsync({ repoId: item.repoId, sourceKey: item.key }); }
				catch { failed.push(aidokuSourceLabel(item.key)); }
			}
			await refreshPreview();
			setConfirm(false);
			if (failed.length) setError(t('aidokuWizard.installFailed', { names: failed.join(', ') }));
		} catch (error) { setError(error instanceof Error ? error.message : t('aidokuWizard.installError')); }
		finally { setBusy(false); }
	}
	return <section aria-label={t('aidokuWizard.recoveryTitle')}>
		<h3>{t('aidokuWizard.recoveryTitle')}</h3>
		<p>{t('aidokuWizard.recoveryHelp')}</p>
		<details className="settings-backup__skipped"><summary>{t('aidokuWizard.howRecovery')}</summary><p>{t('aidokuWizard.exactHelp')}</p></details>
		{ids.length ? <ul>{ids.map((id) => <li key={id}><strong title={id}>{matches.find((entry) => entry.key === id)?.name ?? aidokuSourceLabel(id)}</strong> ({t('aidokuWizard.records', { count: countBySource.get(id) ?? 0 })})
			 — {t(installed.data?.some((source) => source.key === id) ? 'aidokuWizard.installed' : packages.isPending ? 'aidokuWizard.checking' : matches.some((entry) => entry.key === id) ? 'aidokuWizard.available' : 'aidokuWizard.unavailable')}
		</li>)}</ul> : <p>{t('aidokuWizard.noMissing')}</p>}
		{matches.filter((entry) => entry.installedId === null).map((entry) => <label className="repos__lang-row" key={`${entry.repoId}:${entry.key}`}>
			<input type="checkbox" disabled={busy || confirm || recheck.isPending} checked={selected.includes(`${entry.repoId}:${entry.key}`)} onChange={(event) => { const checked = event.currentTarget.checked, key = `${entry.repoId}:${entry.key}`; setSelected((old) => checked ? [...old.filter((item) => !item.endsWith(`:${entry.key}`)), key] : old.filter((item) => item !== key)); }} />
			{entry.name || aidokuSourceLabel(entry.key)} · {entry.repoName ?? t('aidokuWizard.listName', { id: entry.repoId })} · v{entry.version}
		</label>)}
		{packages.isError && <p role="alert">{t('aidokuWizard.listError')}</p>}
		<div className="settings-actions">
			<Button disabled={busy || confirm || recheck.isPending} onClick={onManageLists}>{t('aidokuWizard.manageLists')}</Button>
			<Button disabled={!eligible.length || busy || confirm || recheck.isPending} onClick={() => setConfirm(true)}>{t('aidokuWizard.installSelected', { count: eligible.length })}</Button>
			<Button loading={recheck.isPending} disabled={busy || confirm || recheck.isPending} onClick={() => void refreshPreview()}>{t('aidokuWizard.recheck')}</Button>
		</div>
		{preview.missingSources?.length ? <p className="muted">{t('aidokuWizard.preserveHelp')}</p> : <p className="muted">{t('aidokuWizard.legacyHelp')}</p>}
		{error && <p role="alert">{error}</p>}
		{confirm && <section className="aidoku-wizard__confirmation" aria-label={t('aidokuWizard.confirmInstall')}><h4>{t('aidokuWizard.confirmInstall')}</h4>
			<p>{t('aidokuWizard.confirmHelp')}</p>
			<ul>{matches.filter((entry) => selected.includes(`${entry.repoId}:${entry.key}`)).map((entry) => <li key={`${entry.repoId}:${entry.key}`}>{entry.name || aidokuSourceLabel(entry.key)} — {entry.repoName ?? entry.repoId}</li>)}</ul>
			<div className="settings-actions"><Button disabled={busy} onClick={() => setConfirm(false)}>{t('common.cancel')}</Button><Button variant="primary" loading={busy} disabled={!eligible.length || busy} onClick={() => void installSelected()}>{t('aidokuWizard.installRecheck')}</Button></div>
		</section>}
	</section>;
}
