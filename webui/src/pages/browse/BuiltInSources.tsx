import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { api } from '../../api/client';
import { useSources, useScanLocal } from '../../api/hooks';
import type { Source } from '../../api/types';
import { Button, Input, LocalDirsEditor, Modal } from '../../components';

export const BUILT_INS = [
	{ id: 'local', name: 'Local Files', hint: 'Read supported manga folders, images, CBZ and other local formats.' },
	{ id: 'komga', name: 'Komga', hint: 'Connect to your Komga OPDS catalog with your server credentials.' },
	{ id: 'kavita', name: 'Kavita', hint: 'Use the OPDS URL from Kavita’s third-party client settings.' },
	{ id: 'suwayomi', name: 'Suwayomi', hint: 'Browse and read your Suwayomi library through its live GraphQL API.' }
] as const;
export type BuiltInKind = typeof BUILT_INS[number]['id'];
export function builtInKind(source: Source): string {
	return source.kind === 'local' ? 'local' : String(source.config?.integration ?? 'opds');
}

interface Setup {
	provider: string; name: string; url: string; username: string; password: string;
	paths: string[]; keepCredentials: boolean; sourceId?: number;
}
interface Saved { name: string; paths: string[] | null; hasCredentials: boolean }

async function pickFolders(): Promise<string[]> {
	const bridge = (window as unknown as { webkit?: { messageHandlers?: { chooseLocalFolders?: { postMessage: (value: null) => Promise<unknown> } } } }).webkit?.messageHandlers?.chooseLocalFolders;
	if (!bridge) throw new Error('Type the server’s folder paths below. Native folder selection is available in Sumidoku.app.');
	const result = await bridge.postMessage(null);
	if (!Array.isArray(result) || result.some((p) => typeof p !== 'string')) throw new Error('The folder selection could not be read.');
	return result;
}

function SetupDialog({ kind, source, onClose }: { kind: BuiltInKind; source?: Source; onClose: () => void }) {
	const qc = useQueryClient();
	const preset = BUILT_INS.find((item) => item.id === kind)!;
	const [form, setForm] = useState<Setup>({ provider: kind, name: source?.name ?? preset.name,
		url: '', username: '', password: '', paths: [''], keepCredentials: !!source, sourceId: source?.id });
	const [message, setMessage] = useState('');
	const [loaded, setLoaded] = useState(!source);
	useEffect(() => {
		let active = true;
		if (source) void api<Saved>(`/integrations/${source.id}`).then((saved) => {
			if (active) { setForm((old) => ({ ...old, name: saved.name, paths: saved.paths ?? [''], keepCredentials: saved.hasCredentials })); setLoaded(true); }
		}).catch((error: Error) => { if (active) setMessage(error.message); });
		return () => { active = false; };
	}, [source]);
	const update = (key: keyof Setup, value: string | string[] | boolean) => { setForm((old) => ({ ...old, [key]: value })); setMessage(''); };
	const action = useMutation({ mutationFn: async (test: boolean) => {
		const payload = { ...form, paths: form.paths.map((p) => p.trim()).filter(Boolean) };
		if (test) { await api('/integrations/test', { method: 'POST', body: payload }); setMessage('Connection verified. No chapters downloaded.'); }
		else {
			await api(source ? `/integrations/${source.id}` : '/integrations', { method: source ? 'PUT' : 'POST', body: payload });
			await qc.invalidateQueries({ queryKey: ['sources'] }); onClose();
		}
	}, onError: (error: Error) => setMessage(error.message) });
	return <Modal open title={`${source ? 'Edit' : 'Set Up'} ${preset.name}`} onClose={onClose} footer={<>
		<Button onClick={onClose}>Cancel</Button>
		<Button disabled={!loaded || action.isPending} onClick={() => action.mutate(true)}>Test Connection</Button>
		<Button variant="primary" loading={action.isPending} disabled={!loaded} onClick={() => action.mutate(false)}>Save Connection</Button>
	</>}>
		<div className="opds-form">
			<label>Connection name<Input value={form.name} onChange={(e) => update('name', e.currentTarget.value)} /></label>
			{kind === 'local' ? <>
				<Button onClick={() => void pickFolders().then((paths) => { if (paths.length) update('paths', paths); }).catch((error: Error) => setMessage(error.message))}>Choose Local Folders…</Button>
				<LocalDirsEditor dirs={form.paths} onChange={(paths) => update('paths', paths)} />
				<p className="muted">Files stay in these folders. Connection tests check directory access; scanning is a separate action. Saving titles stores metadata.</p>
			</> : <>
				<label>{kind === 'suwayomi' ? 'Server base URL' : 'Published OPDS catalog URL'}<Input type={kind === 'kavita' ? 'password' : 'url'} autoComplete="off" value={form.url} placeholder={source ? 'Leave blank to keep the saved endpoint' : kind === 'komga' ? 'https://your-server/opds/v2/catalog' : kind === 'suwayomi' ? 'https://your-server/' : 'Paste Kavita’s full private OPDS URL'} onChange={(e) => update('url', e.currentTarget.value)} /></label>
				{source && <label><input type="checkbox" checked={form.keepCredentials} onChange={(e) => update('keepCredentials', e.currentTarget.checked)} /> Keep saved credentials (same server origin only)</label>}
				{!form.keepCredentials && <>
					<label>Username (optional for public servers)<Input autoComplete="off" value={form.username} onChange={(e) => update('username', e.currentTarget.value)} /></label>
					<label>Password<Input type="password" autoComplete="new-password" value={form.password} onChange={(e) => update('password', e.currentTarget.value)} /></label>
				</>}
				<p className="muted">Use HTTPS for credentials beyond this Mac. Public and HTTP Basic connections are supported. Redirects and interactive/OIDC sign-in are rejected with an error.</p>
				{kind === 'suwayomi' && <p className="muted">This is a live library connection, separate from backup import. Extension installation and remote progress sync stay in Suwayomi. No download jobs are started.</p>}
			</>}
			{message && <p role="status">{message}</p>}
		</div>
	</Modal>;
}

export function BuiltInSources() {
	const sources = useSources(); const scan = useScanLocal(); const navigate = useNavigate();
	const [setup, setSetup] = useState<{ kind: BuiltInKind; source?: Source } | null>(null);
	return <section aria-label="Built-in Sources">
		<h2 className="browse__section">Built-in Sources</h2>
		<p className="muted">Ready to configure. No GitHub source list is required.</p>
		{sources.isError && <p role="alert">Saved connections could not be loaded. The built-in setup options remain available.</p>}
		<div className="source-list">{BUILT_INS.map((item) => <div className="source-card" key={item.id} data-integration={item.id}>
			<div className="source-card__main"><h3>{item.name}</h3><p className="muted">{item.hint}</p>
				{(sources.data ?? []).filter((s) => s.kind !== 'aidoku' && builtInKind(s) === item.id).map((source) => <div key={source.id} className="integration-instance">
					<Button onClick={() => navigate(`/browse/${source.id}`)}>{source.name}</Button>
					<Button onClick={() => setSetup({ kind: item.id, source })}>Edit / Test</Button>
					{item.id === 'local' && <Button loading={scan.isPending} onClick={() => scan.mutate(source.id)}>Scan Folders</Button>}
				</div>)}
			</div><Button onClick={() => setSetup({ kind: item.id })}>Set Up</Button>
		</div>)}</div>
		{setup && <SetupDialog key={`${setup.kind}:${setup.source?.id ?? 'new'}`} {...setup} onClose={() => setSetup(null)} />}
		{(sources.data ?? []).filter((s) => s.kind === 'opds' && builtInKind(s) === 'opds').map((source) => <p key={source.id}><Button onClick={() => navigate(`/browse/${source.id}`)}>Existing OPDS connection: {source.name}</Button></p>)}
	</section>;
}
