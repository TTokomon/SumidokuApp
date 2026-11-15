import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useAddSourceRepo } from '../../api/hooks';
import { Button, Input, Modal, pushToast } from '../../components';

export function repoTitle(url: string, name?: string | null): string {
	if (name) return name;
	try {
		return new URL(url).host;
	} catch {
		return url;
	}
}

export function AddRepoModal({ open, onClose }: { open: boolean; onClose: () => void }) {
	const { t } = useTranslation();
	const addRepo = useAddSourceRepo();
	const [url, setUrl] = useState('');
	const [name, setName] = useState('');
	const [error, setError] = useState('');

	// Clear the field each time the modal opens so a half-typed URL from a previous cancel doesn't linger
	useEffect(() => {
		if (open) { setUrl(''); setName(''); setError(''); }
	}, [open]);

	const canSubmit = url.trim() !== '';

	async function submit() {
		const trimmed = url.trim();
		if (!trimmed) return;
		try {
			const repo = await addRepo.mutateAsync({ url: trimmed, ...(name.trim() ? { name: name.trim() } : {}) });
			pushToast(t('reposPanel.repoAdded', { name: repoTitle(repo.url, repo.name) }), 'info');
			onClose();
		} catch (error) { setError(error instanceof Error ? error.message : 'Source list could not be added.'); }
	}

	return (
		<Modal
			open={open}
			title="Add Source List"
			onClose={onClose}
			footer={
				<>
					<Button onClick={onClose}>{t('common.cancel')}</Button>
					<Button variant="primary" loading={addRepo.isPending} disabled={!canSubmit} onClick={() => void submit()}>
						Add Source List
					</Button>
				</>
			}
		>
			<div className="opds-form">
				<label>List name (optional)<Input value={name} onChange={(e) => setName(e.currentTarget.value)} /></label>
				<p className="muted">Paste a GitHub repository URL or its published Aidoku index URL. Compatibility is checked; no repository scripts are executed.</p>
				<Input
					type="url"
					aria-label="GitHub repository or published Aidoku index URL"
					placeholder="https://github.com/owner/repository or published index URL"
					value={url}
					onChange={(e) => setUrl(e.currentTarget.value)}
					autoFocus
				/>
				{error && <p role="alert">{error}</p>}
			</div>
		</Modal>
	);
}
