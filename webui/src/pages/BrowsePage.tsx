import { useMemo, useRef, useState } from 'react';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import {
	ArrowLeftRight,
	CircleArrowUp,
	GripVertical,
	House,
	PackageOpen,
	Pause,
	Pin,
	PinOff,
	Play,
	ScanSearch,
	Search,
	Settings,
	Trash,
	TriangleAlert,
	Upload
} from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { sourceIconUrl } from '../api/client';
import {
	useDeleteSource,
	useImportSource,
	usePinSource,
	useScanSources,
	useSetSourceEnabled,
	useSources,
	useUpdateSource
} from '../api/hooks';
import type { Source } from '../api/types';
import { compareSourceName, contentRatingColor, contentRatingLabel, languageLabel } from '../lib/source';
import {
	Button,
	Chip,
	EmptyState,
	IconButton,
	MenuButton,
	Modal,
	PageHeader,
	SegmentedControl,
	Skeleton,
	Input,
	pushToast
} from '../components';
import ReposPanel from './browse/ReposPanel';
import { SearchPanel } from './browse/SearchPanel';
import { TrashPanel } from './browse/TrashPanel';
import { BuiltInSources } from './browse/BuiltInSources';

import { SourceSettingsButton, SourceSettingsDialog } from './browse/SourceSettingsModal';
import { iconColor } from './browse/iconColor';

function SourceIcon({ source }: { source: Source }) {
	const [failedRevision, setFailedRevision] = useState<number | null>(null);
	if (failedRevision === source.updatedAt) {
		return (
			<span className="source-card__icon-fallback" style={{ background: iconColor(source.key) }}>
				{source.name.slice(0, 1)}
			</span>
		);
	}
	return (
		<span className="source-card__icon">
			<img
				src={sourceIconUrl(source.id, source.updatedAt)}
				alt=""
				loading="lazy"
				referrerPolicy="no-referrer"
				onError={() => setFailedRevision(source.updatedAt)}
			/>
		</span>
	);
}

function useSourceUpdate(source: Source) {
	const { t } = useTranslation();
	const update = useUpdateSource();
	const navigate = useNavigate();

	async function onUpdate() {
		try {
			const r = await update.mutateAsync(source.id);
			pushToast(t('browse.updated', { name: source.name, version: r.version }), 'info');
			for (const w of r.migrationWarnings.slice(0, 3)) pushToast(w, 'info');
			if (r.migrationRequired) {
				pushToast(t('browse.migrationRequired', { name: source.name }), 'info');
				navigate(`/migrate?source=${source.id}&sameSource=1`);
			}
		} catch {
			// client already popped an error toast
		}
	}

	return { onUpdate, pending: update.isPending };
}

function UpdateButton({ source, onUpdate, pending }: { source: Source; onUpdate: () => Promise<void>; pending: boolean }) {
	return (
		<Button
			size="sm"
			variant="primary"
			loading={pending}
			onClick={(e) => {
				e.stopPropagation();
				void onUpdate();
			}}
		>
			<CircleArrowUp size={14} />
			v{source.updateVersion}
		</Button>
	);
}

function ImportAixButton() {
	const { t } = useTranslation();
	const importSource = useImportSource();
	const navigate = useNavigate();
	const inputRef = useRef<HTMLInputElement>(null);

	async function onFile(e: React.ChangeEvent<HTMLInputElement>) {
		const file = e.currentTarget.files?.[0];
		// reset eagerly: re-picking the same file must fire change again, and currentTarget dies with the dispatch
		e.currentTarget.value = '';
		if (!file) return;
		try {
			const r = await importSource.mutateAsync(file);
			pushToast(t('browse.imported', { name: r.name, version: r.version }), 'info');
			for (const w of r.migrationWarnings.slice(0, 3)) pushToast(w, 'info');
			if (r.migrationRequired) {
				pushToast(t('browse.migrationRequired', { name: r.name }), 'info');
				navigate(`/migrate?source=${r.id}&sameSource=1`);
			}
		} catch {
			// client already popped an error toast
		}
	}

	return (
		<>
			<input ref={inputRef} type="file" accept=".aix" hidden onChange={(e) => void onFile(e)} />
			<Button loading={importSource.isPending} onClick={() => inputRef.current?.click()}>
				<Upload size={15} />
				{t('browse.importAix')}
			</Button>
		</>
	);
}

/** Passed when the pinned section's cards enable drag-sorting; the plain list does not pass it */
interface CardDnd {
	dragging: boolean;
	dragOver: boolean;
	onDragStart: (e: React.DragEvent) => void;
	onDragOver: (e: React.DragEvent) => void;
	onDrop: () => void;
	onDragEnd: () => void;
}

export function SourceCard({
	source: s,
	dnd,
	onTogglePin,
	onToggleEnabled,
	onDelete
}: {
	source: Source;
	dnd?: CardDnd;
	onTogglePin: (s: Source) => void;
	onToggleEnabled: (s: Source) => void;
	onDelete: (s: Source) => void;
}) {
	const { t } = useTranslation();
	const navigate = useNavigate();
	const update = useSourceUpdate(s);
	const [settingsOpen, setSettingsOpen] = useState(false);
	const cls = ['source-card'];
	if (s.enabled) cls.push('source-card--link');
	else cls.push('source-card--disabled');
	if (dnd?.dragging) cls.push('source-card--dragging');
	if (dnd?.dragOver) cls.push('source-card--drag-over');
	return (
		<div
			className={cls.join(' ')}
			role={s.enabled ? 'link' : undefined}
			tabIndex={s.enabled ? 0 : undefined}
			onClick={() => s.enabled && navigate(`/browse/${s.id}`)}
			onKeyDown={(e) => {
				if (e.target !== e.currentTarget) return;
				if (s.enabled && (e.key === 'Enter' || e.key === ' ')) {
					e.preventDefault();
					navigate(`/browse/${s.id}`);
				}
			}}
			onDragOver={dnd?.onDragOver}
			onDrop={dnd?.onDrop}
		>
			{dnd && (
				// Only the handle is draggable: making the whole card draggable would turn click-to-navigate into a drag start
				<span
					className="source-card__grip"
					draggable
					onDragStart={dnd.onDragStart}
					onDragEnd={dnd.onDragEnd}
				>
					<GripVertical size={16} />
				</span>
			)}
			<SourceIcon source={s} />
			<div className="source-card__main">
				<div className="source-card__name">
					<span className="source-card__name-text">{s.name}</span>
					{s.contentRating > 0 && (
						<Chip color={contentRatingColor(s.contentRating)}>
							{contentRatingLabel(s.contentRating)}
						</Chip>
					)}
				</div>
				<div className="source-card__meta">
					{s.languages.map(languageLabel).join(', ') || s.key} · v{s.version}
					{!s.enabled ? t('browse.disabled') : ''}
					{s.missingFromRepos && (
						<span
							className="source-card__missing"
							title={t('browse.missingFromRepos')}
						>
							<TriangleAlert size={13} />
						</span>
					)}
				</div>
			</div>
			<div className="source-card__actions">
				<IconButton label={t('aidokuWizard.transferSource', { defaultValue: 'Transfer source' })} onClick={(e) => { e.stopPropagation(); navigate(`/migrate?source=${s.id}`); }}><ArrowLeftRight size={17} /></IconButton>
				{s.updateVersion !== null && <UpdateButton source={s} onUpdate={update.onUpdate} pending={update.pending} />}
				<IconButton
					label={s.pinned ? t('browse.unpin', { name: s.name }) : t('browse.pin', { name: s.name })}
					onClick={(e) => {
						e.stopPropagation();
						onTogglePin(s);
					}}
				>
					{s.pinned ? <PinOff size={17} /> : <Pin size={17} />}
				</IconButton>
				{/* Disabling only gates wasm/opds instantiation today; the local scan reads the filesystem directly */}
				{s.kind !== 'local' && (
					<IconButton
						label={s.enabled ? t('browse.disable', { name: s.name }) : t('browse.enable', { name: s.name })}
						onClick={(e) => {
							e.stopPropagation();
							onToggleEnabled(s);
						}}
					>
						{s.enabled ? <Pause size={17} /> : <Play size={17} />}
					</IconButton>
				)}
				{/* Internal sources (opds) have no wasm home; opds sources get no settings, but local synthesizes home server-side; every source can be uninstalled */}
				{s.kind !== 'opds' && s.hasHome !== false && (
					<IconButton
						label={t('browse.home', { name: s.name })}
						onClick={(e) => {
							e.stopPropagation();
							navigate(`/browse/${s.id}/home`);
						}}
					>
						<House size={17} />
					</IconButton>
				)}
				{s.kind !== 'opds' && <SourceSettingsButton sourceId={s.id} sourceName={s.name} sourceKind={s.kind} />}
				<IconButton
					label={t('browse.uninstall', { name: s.name })}
					variant="danger"
					onClick={(e) => {
						e.stopPropagation();
						onDelete(s);
					}}
				>
					<Trash size={17} />
				</IconButton>
			</div>
			<div className="source-card__mobile-actions">
				<MenuButton label={t('browse.actions', { name: s.name })}>
					{(close) => (
						<>
							{s.updateVersion !== null && (
								<button type="button" className="menu-row" disabled={update.pending} onClick={() => { close(); void update.onUpdate(); }}>
									<span>{t('browse.updateAction', { version: s.updateVersion })}</span>
									<CircleArrowUp size={14} />
								</button>
							)}
							<button type="button" className="menu-row" onClick={() => { close(); navigate(`/migrate?source=${s.id}`); }}><span>{t('aidokuWizard.transferSource', { defaultValue: 'Transfer source' })}</span><ArrowLeftRight size={14} /></button>
							<button type="button" className="menu-row" onClick={() => { close(); onTogglePin(s); }}>
								<span>{s.pinned ? t('browse.unpinAction') : t('browse.pinAction')}</span>
								{s.pinned ? <PinOff size={14} /> : <Pin size={14} />}
							</button>
							{s.kind !== 'local' && (
								<button type="button" className="menu-row" onClick={() => { close(); onToggleEnabled(s); }}>
									<span>{s.enabled ? t('browse.disableAction') : t('browse.enableAction')}</span>
									{s.enabled ? <Pause size={14} /> : <Play size={14} />}
								</button>
							)}
							{s.kind !== 'opds' && s.hasHome !== false && (
								<button type="button" className="menu-row" onClick={() => { close(); navigate(`/browse/${s.id}/home`); }}>
									<span>{t('browse.homeAction')}</span>
									<House size={14} />
								</button>
							)}
							{s.kind !== 'opds' && (
								<button type="button" className="menu-row" onClick={() => { close(); setSettingsOpen(true); }}>
									<span>{t('common.nav.settings')}</span>
									<Settings size={14} />
								</button>
							)}
							<button type="button" className="menu-row menu-row--danger" onClick={() => { close(); onDelete(s); }}>
								<span>{t('browse.uninstallConfirm')}</span>
								<Trash size={14} />
							</button>
						</>
					)}
				</MenuButton>
			</div>
			<SourceSettingsDialog sourceId={s.id} sourceName={s.name} sourceKind={s.kind} open={settingsOpen} onClose={() => setSettingsOpen(false)} />
		</div>
	);
}

export default function BrowsePage() {
	const [params] = useSearchParams();
	if (params.get('view') === 'lists') return <Navigate to="/settings?section=source-lists" replace />;
	return <BrowseSources />;
}

function BrowseSources() {
	const { t } = useTranslation();
	const sources = useSources();
	const navigate = useNavigate();
	const [searchParams, setSearchParams] = useSearchParams();
	const searching = searchParams.get('view') === 'search';
	const rawView = searchParams.get('view');
	const tab = rawView === 'available' || rawView === 'discover' ? 'discover' : rawView === 'trash' ? 'trash' : 'installed';
	const [query, setQuery] = useState(''); const [language, setLanguage] = useState('');
	const [pendingDelete, setPendingDelete] = useState<Source | null>(null);
	const del = useDeleteSource(); const pin = usePinSource(); const setEnabled = useSetSourceEnabled();
	const scan = useScanSources();
	const all = useMemo(() => [...(sources.data ?? [])].filter((source) => source.kind === 'aidoku').sort((a, b) => Number(b.pinned) - Number(a.pinned) || (a.pinned && b.pinned ? (a.pinOrder ?? 0) - (b.pinOrder ?? 0) : 0) || compareSourceName(a, b)), [sources.data]);
	const visible = all.filter((source) => (!query || `${source.name} ${source.key}`.toLowerCase().includes(query.toLowerCase())) && (!language || source.languages.includes(language)));
	async function confirmDelete() {
		if (!pendingDelete) return;
		try { await del.mutateAsync(pendingDelete.id); setPendingDelete(null); } catch { /* error toast */ }
	}
	return <div className="page container sources-page">
		<PageHeader title="Sources" actions={<>
			<Button onClick={() => setSearchParams({ view: 'search' })}><Search size={15} />Search Sources</Button>
			<Button onClick={() => navigate('/migrate')}><ArrowLeftRight size={15} />{t('browse.migrate')}</Button>
			<ImportAixButton />
			<Button loading={scan.isPending} onClick={() => scan.mutate()}><ScanSearch size={15} />{t('browse.scan')}</Button>
		</>} />
		{!searching && <div className="browse__tabs"><SegmentedControl options={[
					{ value: 'installed', label: 'Installed' }, { value: 'discover', label: 'Discover' }, { value: 'trash', label: t('browse.tabTrash') }
				]} value={tab} onChange={(view) => setSearchParams(view === 'installed' ? {} : { view })} /></div>}
		{!searching && tab === 'installed' && <BuiltInSources />}
		<section aria-label="External Sources">
			<h2 className="browse__section">External Sources</h2>
			{!searching && <Link to="/settings?section=source-lists">Source Lists</Link>}
			
			<SearchPanel active={searching} initialQuery={searchParams.get('q') ?? ''} onActiveChange={(active, q) => setSearchParams(active ? { view: 'search', ...(q ? { q } : {}) } : {}, { replace: true })} />
			{!searching && <>

				{tab === 'discover' ? <ReposPanel manage={false} /> : tab === 'trash' ? <TrashPanel /> : <>
					<div className="repos__filters">
						<Input type="search" aria-label="Search installed external sources" placeholder="Search installed sources by name or ID" value={query} onChange={(e) => setQuery(e.currentTarget.value)} />
						<select aria-label="Filter installed source language" value={language} onChange={(e) => setLanguage(e.currentTarget.value)}><option value="">All languages</option>{[...new Set(all.flatMap((s) => s.languages))].sort().map((lang) => <option key={lang} value={lang}>{languageLabel(lang)}</option>)}</select>
					</div>
					{sources.isError && <p role="alert">Installed sources could not be loaded. Try again when the server is available.</p>}
					{sources.isPending ? <Skeleton height={82} /> : !visible.length ? <EmptyState icon={PackageOpen} title="No matching installed external sources" hint="Discover available sources or subscribe in Source Lists." /> : <div className="source-groups">{([{ label: 'Pinned', items: visible.filter(s => s.pinned) }, { label: 'Installed', items: visible.filter(s => !s.pinned) }]).filter(group => group.items.length > 0).map(group => <section key={group.label}>
						<h3 className="source-group-heading">{group.label} <span className="muted">{group.items.length}</span></h3>
						<div className="source-list">{group.items.map(source => <SourceCard key={source.id} source={source} onTogglePin={(s) => pin.mutate({ id: s.id, pinned: !s.pinned })} onToggleEnabled={(s) => setEnabled.mutate({ id: s.id, enabled: !s.enabled })} onDelete={setPendingDelete} />)}</div>
					</section>)}</div>}
				</>}
			</>}
		</section>
		<Modal open={pendingDelete !== null} title={`Uninstall ${pendingDelete?.name ?? 'source'}?`} onClose={() => setPendingDelete(null)} footer={<>
			<Button onClick={() => setPendingDelete(null)}>Cancel</Button><Button variant="danger" loading={del.isPending} onClick={() => void confirmDelete()}>Uninstall Package</Button>
		</>}><p>The source package will be removed. Saved library entries, categories and reading progress stay in your database for an exact-ID reinstall. Existing downloaded files are not removed.</p></Modal>
	</div>;
}
