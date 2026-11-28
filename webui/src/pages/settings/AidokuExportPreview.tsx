import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { api } from '../../api/client';
import type { AidokuExportPreview as ExportPreview } from '../../api/types';
import { Button } from '../../components';

const endpoint = '/backups/export/aidoku?completeBackup=true';

export function AidokuExportPreview() {
	const { t } = useTranslation();
	const [file, setFile] = useState<File | null>(null);
	const [complete, setComplete] = useState(false);
	const [preview, setPreview] = useState<ExportPreview | null>(null);
	const requestPreview = useMutation({
		mutationFn: (backup: File) => api<ExportPreview>(endpoint, { method: 'POST', body: backup }),
		onMutate: () => setPreview(null),
		onSuccess: setPreview
	});
	const download = useMutation({
		mutationFn: ({ backup, fingerprint }: { backup: File; fingerprint: string }) =>
			api<Blob>(endpoint + '&previewFingerprint=' + encodeURIComponent(fingerprint), {
				method: 'POST', body: backup, responseType: 'blob'
			}),
		onError: () => setPreview(null),
		onSuccess: (blob) => {
			const url = URL.createObjectURL(blob);
			const link = document.createElement('a');
			link.href = url;
			link.download = 'sumidoku-aidoku-progress.aib';
			document.body.append(link);
			link.click();
			link.remove();
			window.setTimeout(() => URL.revokeObjectURL(url), 30_000);
		}
	});
	const busy = requestPreview.isPending || download.isPending;
	return <details className="settings-backup__advanced">
		<summary>{t('aidokuExport.title', { defaultValue: 'Export for Aidoku' })}</summary>
		<p>{t('aidokuExport.help', { defaultValue: 'Export a fresh backup from the target Aidoku device with library entries, chapters, history, reading sessions, and updates enabled. Turn off sensitive settings. Keep the original as a recovery copy.' })}</p>
		<label>
			{t('aidokuExport.targetBackup', { defaultValue: 'Fresh Aidoku backup' })}
			<input type="file" accept=".aib" disabled={busy} onChange={(event) => {
				setFile(event.currentTarget.files?.[0] ?? null);
				setComplete(false);
				setPreview(null);
			}} />
		</label>
		<label className="aidoku-wizard__ack">
			<input type="checkbox" checked={complete} disabled={busy || !file} onChange={(event) => {
				setComplete(event.currentTarget.checked);
				setPreview(null);
			}} />
			{t('aidokuExport.complete', { defaultValue: 'I included all five sections from the target device.' })}
		</label>
		<Button disabled={!file || !complete || busy} loading={requestPreview.isPending} onClick={() => file && requestPreview.mutate(file)}>
			{t('aidokuExport.preview', { defaultValue: 'Review progress export' })}
		</Button>
		{preview && <div>
			<p>{t('aidokuExport.counts', { defaultValue: '{{history}} history records, {{sessions}} reading sessions, {{chapters}} chapters, and {{updates}} updates.', history: preview.history, sessions: preview.readingSessions, chapters: preview.chapters, updates: preview.updates })}</p>
			<p>{t('aidokuExport.changes', { defaultValue: 'History changes: {{added}} added, {{changed}} changed, {{removed}} removed.', added: preview.addedHistory, changed: preview.changedHistory, removed: preview.removedHistory })}</p>
			<p>{t('aidokuExport.omitted', { defaultValue: 'Library, categories, trackers, source subscriptions and settings are outside this export.' })}</p>
			{preview.fixtureDownloadEnabled ? <>
				<p>{t('aidokuExport.fixtureWarning', { defaultValue: 'Use only with a disposable Aidoku profile without downloads. Keep the original backup, and do not read or edit in Aidoku between export and the restore test.' })}</p>
				<Button disabled={!file || busy} loading={download.isPending} onClick={() => file && download.mutate({ backup: file, fingerprint: preview.previewFingerprint })}>
					{t('aidokuExport.downloadFixture', { defaultValue: 'Download restore test file' })}
				</Button>
			</> : <p>{t('aidokuExport.gated', { defaultValue: 'Download is disabled until restore is verified in official Aidoku.' })}</p>}
		</div>}
	</details>;
}
