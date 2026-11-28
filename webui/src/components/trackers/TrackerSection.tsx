import { useState } from 'react';
import type { FormEvent } from 'react';
import { useMutation, useQueries, useQuery, useQueryClient } from '@tanstack/react-query';
import { ExternalLink, Plus, RefreshCw, Search } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import {
	TRACKER_PROVIDER_NAMES,
	availableTrackerProviders,
	buildTrackerSave,
	deleteTrackerLink,
	hasTrackUpdate,
	invalidateTrackerLinks,
	isTrackerAuthError,
	trackerErrorMessage,
	listTrackerLinks,
	mergeTrackEditValues,
	oauthStartUrl,
	preferredTrackerProvider,
	putTrackerLink,
	remoteToTrackEdit,
	searchTracker,
	syncTrackerLink,
	trackerEntryUrl,
	trackerKeys,
	trackerMediaLabelKey,
	trackerPreferences,
	trackerState,
	updateTrackEditValue,
	updateTracker
} from '../../api/trackers';
import { qk } from '../../api/hooks';
import type {
	Chapter,
	RemoteState,
	TrackSearchItem,
	TrackStatus,
	TrackerLink,
	TrackerProvider,
	TrackerSyncResult
} from '../../api/types';
import { Badge, Button, Cover, Input, Modal, SegmentedControl, Skeleton, Spinner, pushToast } from '..';
import { TrackerLogo } from './TrackerLogo';
import './trackers.css';

const TRACK_MODES = ['auto', 'chapter', 'volume'] as const satisfies readonly TrackerLink['trackMode'][];
const TRACK_MODE_LABELS: Record<TrackerLink['trackMode'], string> = {
	auto: 'modeAuto',
	chapter: 'modeChapter',
	volume: 'modeVolume'
};
const TRACK_STATUSES = ['reading', 'planning', 'completed', 'paused', 'dropped', 'rereading'] as const satisfies readonly TrackStatus[];

function TrackerAuthNotice({ provider, reconnect = false }: { provider: TrackerProvider; reconnect?: boolean }) {
	const { t } = useTranslation();
	const name = TRACKER_PROVIDER_NAMES[provider];
	return (
		<div className="tracker-auth" role="alert">
			<p>{t('trackers.authRequired', { provider: name })}</p>
			<Button size="sm" variant="primary" onClick={() => window.location.assign(oauthStartUrl(provider))}>
				{reconnect ? t('trackers.reconnect') : t('trackers.connect')}
			</Button>
		</div>
	);
}

function TrackerPill({ link, onClick }: { link: TrackerLink; onClick: () => void }) {
	const { t } = useTranslation();
	const stateQuery = useQuery({
		queryKey: trackerKeys.state(link.provider, link.trackId),
		queryFn: () => trackerState(link.provider, link.trackId),
		retry: false,
		refetchOnWindowFocus: false
	});
	const disconnected = isTrackerAuthError(stateQuery.error);
	const provider = TRACKER_PROVIDER_NAMES[link.provider];
	const status = stateQuery.data?.status;
	return (
		<button
			type="button"
			className={disconnected ? 'tracker-pill tracker-pill--disconnected' : 'tracker-pill'}
			onClick={onClick}
			title={disconnected ? t('trackers.authRequired', { provider }) : undefined}
		>
			<TrackerLogo provider={link.provider} />
			<span className="tracker-pill__provider">{provider}</span>
			{!stateQuery.isPending && !disconnected && status && (
				<span className="tracker-pill__status">{t(`trackers.statusValues.${status}`)}</span>
			)}
			{disconnected && <span className="tracker-pill__auth" aria-label={t('trackers.authRequired', { provider })} />}
		</button>
	);
}

interface AddTrackerDialogProps {
	mangaId: number;
	mangaTitle: string;
	providers: TrackerProvider[];
	onClose: () => void;
	onBound: (link: TrackerLink) => void;
}

function AddTrackerDialog({ mangaId, mangaTitle, providers, onClose, onBound }: AddTrackerDialogProps) {
	const { t } = useTranslation();
	const qc = useQueryClient();
	const preferencesQuery = useQuery({ queryKey: trackerKeys.preferences, queryFn: trackerPreferences });
	const [picked, setProvider] = useState<TrackerProvider | null>(null);
	const provider = picked ?? preferredTrackerProvider(preferencesQuery.data?.defaultTracker, providers);
	const [draft, setDraft] = useState(mangaTitle);
	const [submitted, setSubmitted] = useState('');
	const searchQuery = useQuery({
		queryKey: trackerKeys.search(provider, submitted),
		queryFn: () => searchTracker(provider, submitted),
		enabled: submitted.length > 0,
		retry: false
	});
	const bind = useMutation({
		mutationFn: (item: TrackSearchItem) =>
			putTrackerLink(mangaId, { provider, trackId: item.id, title: item.title }),
		onSuccess: (link) => {
			invalidateTrackerLinks(qc, mangaId);
			onBound(link);
		}
	});

	function submitSearch(event?: FormEvent) {
		event?.preventDefault();
		const name = draft.trim();
		if (!name) {
			setSubmitted('');
			return;
		}
		if (name === submitted) void searchQuery.refetch();
		else setSubmitted(name);
	}

	return (
		<Modal open title={t('trackers.addBinding')} onClose={onClose} panelClassName="modal__panel--wide">
			<div className="tracker-add">
				<div className="tracker-add__providers">
					<SegmentedControl
						value={provider}
						disabled={bind.isPending}
						options={providers.map((item) => ({
							value: item,
							label: (
								<span className="tracker-seg__option">
									<TrackerLogo provider={item} />
									<span>{TRACKER_PROVIDER_NAMES[item]}</span>
								</span>
							)
						}))}
						onChange={(item) => {
							setProvider(item);
							setDraft(mangaTitle);
							setSubmitted('');
						}}
					/>
				</div>
				<form className="tracker-search" onSubmit={submitSearch}>
					<Input
						icon={<Search size={15} />}
						type="search"
						value={draft}
						aria-label={t('common.search')}
						onChange={(event) => setDraft(event.currentTarget.value)}
					/>
					<Button type="submit" variant="primary" loading={searchQuery.isFetching && submitted.length > 0}>
						{t('common.search')}
					</Button>
				</form>
				{searchQuery.isPending && submitted ? (
					<div className="tracker-dialog-state">
						<Spinner />
						{t('trackers.searching')}
					</div>
				) : searchQuery.isError ? (
					isTrackerAuthError(searchQuery.error) ? (
						<TrackerAuthNotice provider={provider} />
					) : (
						<div className="tracker-dialog-state tracker-error" role="alert">
							<span>{trackerErrorMessage(searchQuery.error)}</span>
							<Button size="sm" onClick={() => void searchQuery.refetch()}>
								{t('trackers.retry')}
							</Button>
						</div>
					)
				) : searchQuery.data ? (
					searchQuery.data.length === 0 ? (
						<p className="tracker-dialog-state muted">{t('trackers.noResults')}</p>
					) : (
						<ul className="tracker-results">
							{searchQuery.data.map((item) => (
								<li className="tracker-result" key={item.id}>
									<div className="tracker-result__cover">
										<Cover src={item.coverUrl} title={item.title} />
									</div>
									<div className="tracker-result__meta">
										<h4>{item.title}</h4>
										{item.info && <p className="tracker-result__info">{item.info}</p>}
										{item.description && (
											<p className="tracker-result__description" title={item.description}>
												{item.description}
											</p>
										)}
										<div className="tracker-result__badges">
											<MediaBadge item={item} />
											{item.tracked && <Badge>{t('trackers.tracked')}</Badge>}
										</div>
									</div>
									<Button size="sm" disabled={bind.isPending} onClick={() => bind.mutate(item)}>
										{t('trackers.bind')}
									</Button>
								</li>
							))}
						</ul>
					)
				) : null}
			</div>
		</Modal>
	);
}

interface TrackerEditFormProps {
	link: TrackerLink;
	initialState: RemoteState | null;
	onClose: () => void;
}

export function TrackerEditForm({ link, initialState, onClose }: TrackerEditFormProps) {
	const { t } = useTranslation();
	const qc = useQueryClient();
	const [currentLink, setCurrentLink] = useState(link);
	const [edits, setEdits] = useState<Partial<ReturnType<typeof remoteToTrackEdit>>>({});
	const values = mergeTrackEditValues(initialState, edits);
	const [trackMode, setTrackMode] = useState<TrackerLink['trackMode']>(link.trackMode);
	const [chapterOffset, setChapterOffset] = useState(String(link.chapterOffset));
	const [confirmUnlink, setConfirmUnlink] = useState(false);
	const provider = TRACKER_PROVIDER_NAMES[link.provider];
	const save = useMutation({
		mutationFn: async () => {
			const plan = buildTrackerSave(currentLink, trackMode, Number(chapterOffset), initialState, values);
			if (plan.link) setCurrentLink(await putTrackerLink(currentLink.mangaId, plan.link));
			if (hasTrackUpdate(plan.remoteUpdate)) {
				await updateTracker(link.provider, { trackId: link.trackId, ...plan.remoteUpdate });
			}
		},
		onSuccess: () => {
			pushToast(t('trackers.saved'), 'info');
			onClose();
		},
		onSettled: () => {
			invalidateTrackerLinks(qc, link.mangaId);
			void qc.invalidateQueries({ queryKey: trackerKeys.state(link.provider, link.trackId) });
		}
	});
	const unlink = useMutation({
		mutationFn: () => deleteTrackerLink(link.mangaId, link.provider),
		onSuccess: () => {
			invalidateTrackerLinks(qc, link.mangaId);
			setConfirmUnlink(false);
			pushToast(t('trackers.unlinked'), 'info');
			onClose();
		}
	});
	// Aidoku's "Sync Local History": preview what a pull from this tracker
	// would mark read, ask, then apply. Applying pushes the new progress to
	// the manga's other bindings server-side (the source tracker is skipped).
	const [syncPreview, setSyncPreview] = useState<TrackerSyncResult | null>(null);
	const applySync = useMutation({
		mutationFn: () => syncTrackerLink(currentLink.mangaId, currentLink.provider),
		onSuccess: (result) => {
			pushToast(t('trackers.syncDone', { count: result.marked }), 'info');
			setSyncPreview(null);
			onClose();
		},
		onSettled: () => {
			void qc.invalidateQueries({ queryKey: qk.chapters(currentLink.mangaId) });
			void qc.invalidateQueries({ queryKey: trackerKeys.state(link.provider, link.trackId) });
			invalidateTrackerLinks(qc, link.mangaId);
		}
	});
	const previewSync = useMutation({
		mutationFn: () => syncTrackerLink(currentLink.mangaId, currentLink.provider, true),
		onSuccess: (plan) => {
			applySync.reset();
			setSyncPreview(plan);
		}
	});
	const saveAuthError = isTrackerAuthError(save.error);

	function updateValue<K extends keyof typeof values>(field: K, value: (typeof values)[K]) {
		setEdits((current) => updateTrackEditValue(initialState, current, field, value));
	}

	function submit(event: FormEvent) {
		event.preventDefault();
		save.mutate();
	}

	return (
		<>
			<form className="tracker-edit" onSubmit={submit}>
				{save.isError &&
					(saveAuthError ? (
						<TrackerAuthNotice provider={link.provider} reconnect />
					) : (
						<p className="tracker-error" role="alert">
							{trackerErrorMessage(save.error)}
						</p>
					))}
				<div className="tracker-edit__mode">
					<SegmentedControl
						options={TRACK_MODES.map((mode) => ({ value: mode, label: t(`trackers.${TRACK_MODE_LABELS[mode]}`) }))}
						value={trackMode}
						onChange={setTrackMode}
					/>
				</div>
				<label className="tracker-field">
					<span>{t('trackers.chapterOffset')}</span>
					<Input
						type="number"
						min={-10000}
						max={10000}
						step={1}
						required
						value={chapterOffset}
						onChange={(event) => setChapterOffset(event.currentTarget.value)}
					/>
					<span className="tracker-field__hint">{t('trackers.chapterOffsetHint')}</span>
				</label>
				<div className="tracker-edit__remote">
					<div className="tracker-edit__remote-head">
						<div className="tracker-edit__remote-id">
							<span>{t('trackers.remoteEntry')}</span>
							<span className="tracker-edit__track-id">#{link.trackId}</span>
						</div>
						<a
							className="tracker-edit__external"
							href={trackerEntryUrl(link.provider, link.trackId)}
							target="_blank"
							rel="noreferrer"
						>
							{t('trackers.openEntry', { provider })}
							<ExternalLink size={14} />
						</a>
					</div>
					{initialState && (
						<div className="tracker-edit__remote-fields">
							<div className="tracker-edit__status">
								<SegmentedControl
									options={TRACK_STATUSES.map((status) => ({
										value: status as TrackStatus | '',
										label: t(`trackers.statusValues.${status}`)
									}))}
									value={values.status}
									onChange={(status) => {
										if (status) updateValue('status', status);
									}}
								/>
							</div>
							<div className="tracker-edit__progress">
								<label className="tracker-field">
									<span>{t('trackers.score')}</span>
									<Input
										type="number"
										min={0}
										step={1}
										value={values.score}
										onChange={(event) => updateValue('score', event.currentTarget.value)}
									/>
								</label>
								<label className="tracker-field">
									<span>{t('trackers.chapterProgress')}</span>
									<Input
										type="number"
										min={0}
										step="any"
										value={values.lastReadChapter}
										onChange={(event) => updateValue('lastReadChapter', event.currentTarget.value)}
									/>
								</label>
								<label className="tracker-field">
									<span>{t('trackers.volumeProgress')}</span>
									<Input
										type="number"
										min={0}
										step={1}
										value={values.lastReadVolume}
										onChange={(event) => updateValue('lastReadVolume', event.currentTarget.value)}
									/>
								</label>
							</div>
						</div>
					)}
				</div>
				{previewSync.isError &&
					(isTrackerAuthError(previewSync.error) ? (
						<TrackerAuthNotice provider={link.provider} reconnect />
					) : (
						<p className="tracker-error" role="alert">
							{trackerErrorMessage(previewSync.error)}
						</p>
					))}
				<div className="tracker-edit__actions">
					<Button variant="danger" onClick={() => setConfirmUnlink(true)}>
						{t('trackers.unlink')}
					</Button>
					<div className="tracker-edit__save">
						<Button onClick={() => previewSync.mutate()} loading={previewSync.isPending}>
							<RefreshCw size={14} />
							{t('trackers.syncFromTracker')}
						</Button>
						<Button type="submit" variant="primary" loading={save.isPending}>
							{t('common.save')}
						</Button>
					</div>
				</div>
			</form>
			<Modal
				open={syncPreview !== null}
				title={t('trackers.syncTitle')}
				onClose={() => setSyncPreview(null)}
				footer={
					syncPreview !== null && syncPreview.marked > 0 ? (
						<>
							<Button onClick={() => setSyncPreview(null)}>{t('common.cancel')}</Button>
							<Button variant="primary" loading={applySync.isPending} onClick={() => applySync.mutate()}>
								{t('trackers.syncFromTracker')}
							</Button>
						</>
					) : (
						<Button variant="primary" onClick={() => setSyncPreview(null)}>
							{t('common.cancel')}
						</Button>
					)
				}
			>
				{syncPreview !== null &&
					(syncPreview.marked > 0 ? (
						<p>{t('trackers.syncConfirm', { count: syncPreview.marked, provider, progress: syncPreview.progress })}</p>
					) : (
						<p>{t('trackers.syncUpToDate', { provider })}</p>
					))}
				{applySync.isError && (
					<p className="tracker-error" role="alert">
						{trackerErrorMessage(applySync.error)}
					</p>
				)}
			</Modal>
			<Modal
				open={confirmUnlink}
				title={t('trackers.unlinkTitle')}
				onClose={() => setConfirmUnlink(false)}
				footer={
					<>
						<Button onClick={() => setConfirmUnlink(false)}>{t('common.cancel')}</Button>
						<Button variant="danger" loading={unlink.isPending} onClick={() => unlink.mutate()}>
							{t('trackers.unlink')}
						</Button>
					</>
				}
			>
				<p>{t('trackers.unlinkConfirm', { provider, title: link.title ?? link.trackId })}</p>
			</Modal>
		</>
	);
}

function EditTrackerDialog({ link, onClose }: { link: TrackerLink; onClose: () => void }) {
	const { t } = useTranslation();
	const remoteQuery = useQuery({
		queryKey: trackerKeys.state(link.provider, link.trackId),
		queryFn: () => trackerState(link.provider, link.trackId),
		retry: false,
		refetchOnWindowFocus: false
	});
	const provider = TRACKER_PROVIDER_NAMES[link.provider];
	return (
		<Modal
			open
			title={t('trackers.editBinding', { provider })}
			onClose={onClose}
			panelClassName="modal__panel--wide"
		>
			{remoteQuery.isPending ? (
				<div className="tracker-dialog-state">
					<Spinner />
					{t('common.loading')}
				</div>
			) : (
				<>
					{remoteQuery.isError &&
						(isTrackerAuthError(remoteQuery.error) ? (
							<TrackerAuthNotice provider={link.provider} reconnect />
						) : (
							<div className="tracker-dialog-state tracker-error" role="alert">
								<span>{trackerErrorMessage(remoteQuery.error)}</span>
								<Button size="sm" onClick={() => void remoteQuery.refetch()}>
									{t('trackers.retry')}
								</Button>
							</div>
						))}
					<TrackerEditForm link={link} initialState={remoteQuery.data ?? null} onClose={onClose} />
				</>
			)}
		</Modal>
	);
}

type LocalReading = Pick<Chapter, 'title' | 'chapter_number' | 'volume_number' | 'lastPageRead' | 'lastReadAt' | 'isRead'>;

export function TrackerProgressComparison({ links, chapters }: { links: TrackerLink[]; chapters?: LocalReading[] }) {
	const { t, i18n } = useTranslation();
	const snapshots = useQueries({ queries: links.map(link => ({
		queryKey: trackerKeys.state(link.provider, link.trackId),
		queryFn: () => trackerState(link.provider, link.trackId),
		retry: false,
		refetchOnWindowFocus: false
	})) });
	const latest = chapters?.reduce<LocalReading | undefined>((current, chapter) =>
		(chapter.lastReadAt ?? 0) > (current?.lastReadAt ?? 0) ? chapter : current, undefined);
	const locale = i18n.resolvedLanguage || 'en';
	const format = new Intl.NumberFormat(locale);
	const dateTime = new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' });
	const unknown = t('trackers.observationUnavailable', { defaultValue: 'Unavailable' });
	const display = (value: number | null | undefined) => value == null ? unknown : format.format(value);
	const observedAt = (millis: number) => Number.isNaN(new Date(millis).getTime()) ? unknown : dateTime.format(millis);
	const chapterLabel = t('trackers.chapterProgress');
	const volumeLabel = t('trackers.volumeProgress');
	return <div className="tracker-comparison">
		<p>{t('trackers.comparisonHelp', { defaultValue: 'Sumidoku shows the last saved chapter and page. Each provider shows its series-level reading progress. Verify account and title associations before making corrections.' })}</p>
		<section>
			<h3>Sumidoku</h3>
			{latest ? <dl>
				<dt>{chapterLabel}</dt><dd>{latest.title ?? display(latest.chapter_number)}{latest.title && latest.chapter_number !== null ? ` (${display(latest.chapter_number)})` : ''}</dd>
				<dt>{volumeLabel}</dt><dd>{display(latest.volume_number)}</dd>
				<dt>{t('trackers.localPagePosition', { defaultValue: 'Saved page position' })}</dt><dd>{display(latest.lastPageRead)}</dd>
				<dt>{t('trackers.observedStatus', { defaultValue: 'Status' })}</dt><dd>{latest.isRead ? t('trackers.localChapterRead', { defaultValue: 'Chapter read' }) : t('trackers.localChapterUnread', { defaultValue: 'Chapter unfinished' })}</dd>
				<dt>{t('trackers.observedAt', { defaultValue: 'Recorded at' })}</dt><dd>{observedAt((latest.lastReadAt ?? 0) * 1000)}</dd>
			</dl> : <p>{chapters ? t('trackers.noLocalHistory', { defaultValue: 'No saved reading history' }) : unknown}</p>}
		</section>
		{links.map((link, index) => {
			const snapshot = snapshots[index];
			const remote = !snapshot.isError ? snapshot.data : undefined;
			const provider = TRACKER_PROVIDER_NAMES[link.provider];
			return <section key={link.provider}>
				<h3>{provider}</h3>
				<p>{link.title ?? link.trackId}</p>
				{remote ? <dl>
					<dt>{chapterLabel}</dt><dd>{display(remote.lastReadChapter)}</dd>
					<dt>{volumeLabel}</dt><dd>{display(remote.lastReadVolume)}</dd>
					<dt>{t('trackers.score')}</dt><dd>{display(remote.score)}</dd>
					<dt>{t('trackers.observedStatus', { defaultValue: 'Status' })}</dt><dd>{remote.status ? t(`trackers.statusValues.${remote.status}`) : unknown}</dd>
					<dt>{t('trackers.observedStart', { defaultValue: 'Started' })}</dt><dd>{remote.startReadDate ?? unknown}</dd>
					<dt>{t('trackers.observedFinish', { defaultValue: 'Finished' })}</dt><dd>{remote.finishReadDate ?? unknown}</dd>
					<dt>{t('trackers.observedAt', { defaultValue: 'Recorded at' })}</dt><dd>{observedAt(snapshot.dataUpdatedAt)}</dd>
				</dl> : <p>{snapshot.isPending ? t('common.loading') : isTrackerAuthError(snapshot.error) ? t('trackers.authRequired', { provider }) : unknown}</p>}
			</section>;
		})}
	</div>;
}

export function TrackerSection({ mangaId, mangaTitle, chapters }: { mangaId: number; mangaTitle: string; chapters?: LocalReading[] }) {
	const { t } = useTranslation();
	const [adding, setAdding] = useState(false);
	const [editing, setEditing] = useState<TrackerLink | null>(null);
	const [comparing, setComparing] = useState(false);
	const linksQuery = useQuery({
		queryKey: trackerKeys.mangaLinks(mangaId),
		queryFn: () => listTrackerLinks(mangaId)
	});
	const links = linksQuery.data ?? [];
	const providers = availableTrackerProviders(links);
	const canAdd = linksQuery.isSuccess && providers.length > 0;
	return (
		<section className="tracker-section">
			<div className="tracker-section__head">
				<h2>{t('trackers.sectionTitle')}</h2>
				<Button
					size="sm"
					disabled={!canAdd}
					title={linksQuery.isSuccess && providers.length === 0 ? t('trackers.allProvidersBound') : undefined}
					onClick={() => setAdding(true)}
				>
					<Plus size={15} />
					{t('trackers.addBinding')}
				</Button>
			</div>
			{linksQuery.isPending ? (
				<Skeleton height={48} />
			) : linksQuery.isError ? (
				<p className="tracker-error">{linksQuery.error.message}</p>
			) : links.length === 0 ? (
				<p className="tracker-section__empty">{t('trackers.noMangaBindings')}</p>
			) : (
				<div className="tracker-pills">
					{links.map((link) => (
						<TrackerPill key={link.provider} link={link} onClick={() => setEditing(link)} />
					))}
					<Button size="sm" onClick={() => setComparing(true)}>{t('trackers.compareProgress', { defaultValue: 'Compare reading progress' })}</Button>
				</div>
			)}
			{adding && canAdd && (
				<AddTrackerDialog
					mangaId={mangaId}
					mangaTitle={mangaTitle}
					providers={providers}
					onClose={() => setAdding(false)}
					onBound={(link) => {
						setAdding(false);
						setEditing(link);
					}}
				/>
			)}
			{editing && <EditTrackerDialog key={`${editing.provider}:${editing.trackId}`} link={editing} onClose={() => setEditing(null)} />}
			{comparing && <Modal open title={t('trackers.compareProgress', { defaultValue: 'Compare reading progress' })} onClose={() => setComparing(false)}>
				<TrackerProgressComparison links={links} chapters={chapters} />
			</Modal>}
		</section>
	);
}

function MediaBadge({ item }: { item: TrackSearchItem }) {
	const { t } = useTranslation();
	const key = trackerMediaLabelKey(item);
	return key ? <Badge>{t(key)}</Badge> : null;
}
