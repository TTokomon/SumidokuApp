import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import { Trans, useTranslation } from 'react-i18next';
import { ArrowLeft, ArrowRight, Search, TriangleAlert } from 'lucide-react';
import { coverUrl } from '../../api/client';
import { useLibrary, useMigrate, useMigrateSources } from '../../api/hooks';
import type { LibraryEntry, MigrateMode, MigrateResult, SearchManga } from '../../api/types';
import { mapPool } from '../../lib/pool';
import { compareSourceName } from '../../lib/source';
import {
	Button,
	Cover,
	EmptyState,
	Input,
	MenuButton,
	Modal,
	PageHeader,
	Skeleton,
	Spinner,
	pushToast
} from '../../components';
import { DestinationPicker } from './DestinationPicker';
import { uniqueTitleMatch } from './matchCandidate';
import { searchDestinations } from './searchDestinations';
import './migrate.css';

type Step = 'source' | 'series' | 'destinations' | 'match';

interface Row {
	manga: LibraryEntry;
	state: 'pending' | 'matching' | 'matched' | 'notfound';
	target?: SearchManga;
	candidates?: SearchManga[];
	failedSources?: number[];
	result?: MigrateResult;
}


async function autoMatch(
	rows: Row[], destinations: number[], signal: AbortSignal, update: (id: number, patch: Partial<Row>) => void
) {
	await mapPool(rows, 3, async (row) => {
		if (signal.aborted) return;
		update(row.manga.id, { state: 'matching' });
		const { candidates, failures } = await searchDestinations(row.manga, destinations, signal);
		if (signal.aborted) return;
		const target = failures.length === 0 ? uniqueTitleMatch(row.manga, candidates) : undefined;
		update(row.manga.id, {
			state: target ? 'matched' : 'notfound', target, candidates, failedSources: failures
		});
	});
}

function Reason({ item }: { item: MigrateResult }) {
	const { t } = useTranslation();
	const text: Record<string, string> = {
		not_found: t('migrate.reason.not_found'),
		not_in_library: t('migrate.reason.not_in_library'),
		source_not_found: t('migrate.reason.source_not_found'),
		same_source: t('migrate.reason.same_source'),
		fetch_failed: item.message
			? t('migrate.reason.fetch_failed_with_message', { message: item.message })
			: t('migrate.reason.fetch_failed')
	};
	return <span className="migrate-row__reason">{text[item.reason ?? ''] ?? item.reason}</span>;
}

export default function MigratePage() {
	const { t } = useTranslation();
	const [params] = useSearchParams();
	const navigate = useNavigate();
	const location = useLocation();
	const [incoming] = useState<LibraryEntry[]>(() => Array.isArray(location.state?.transferEntries) ? location.state.transferEntries.filter((entry: LibraryEntry) => entry.inLibrary && Number.isSafeInteger(entry.id)) : []);
	// breaking-change guidance entry: ?source=<id> prefills the origin, sameSource=1 allows and preselects a same-source target
	const prefill = Number(params.get('source')) || null;
	const sameSource = params.get('sameSource') === '1';
	const [step, setStep] = useState<Step>(incoming.length ? 'destinations' : prefill ? 'series' : 'source');
	const [sourceId, setSourceId] = useState<number | null>(prefill);
	const [selectingAll, setSelectingAll] = useState(false);
	const searchRequest = useRef<AbortController | null>(null);
	useEffect(() => () => searchRequest.current?.abort(), []);
	const [selected, setSelected] = useState<Set<number>>(() => new Set(incoming.map(entry => entry.id)));
	const [destinations, setDestinations] = useState<number[]>(
		sameSource && prefill ? [prefill] : []
	);
	const [rows, setRows] = useState<Row[]>([]);
	const [matching, setMatching] = useState(false);
	const [confirmMode, setConfirmMode] = useState<MigrateMode | null>(null);
	const [rematchRow, setRematchRow] = useState<Row | null>(null);
	const [executed, setExecuted] = useState(false);

	const sourcesQuery = useMigrateSources();
	const libraryQuery = useLibrary({ sourceId: sourceId ?? undefined });
	const migrate = useMigrate();

	// The migration source list sorts alphabetically by name, same as the installed-source list
	const migrateSources = useMemo(
		() => [...(sourcesQuery.data ?? [])].sort(compareSourceName),
		[sourcesQuery.data]
	);

	const series = useMemo(
		() => incoming.length ? incoming : (libraryQuery.data?.pages.flatMap((p) => p.entries) ?? []),
		[libraryQuery.data, sourceId, incoming]
	);
	const sourceName = incoming.length ? t('aidokuWizard.selectedTitles', { defaultValue: 'Selected titles' }) : ((sourcesQuery.data ?? []).find((s) => s.id === sourceId)?.name ?? '');
	const eligibleDestinations = destinations.filter((id) => sourcesQuery.data?.some((source) => source.id === id && source.enabled));
	const destName = (id: number) => (sourcesQuery.data ?? []).find((s) => s.id === id)?.name ?? `#${id}`;

	const MODE_LABEL: Record<MigrateMode, string> = {
		copy: t('migrate.mode.copy'),
		migrate: t('migrate.mode.migrate'),
		migrateWithHistory: t('migrate.mode.migrateWithHistory')
	};
	const MODE_HINT: Record<MigrateMode, string> = {
		copy: t('migrate.modeHint.copy'),
		migrate: t('migrate.modeHint.migrate'),
		migrateWithHistory: t('migrate.modeHint.migrateWithHistory')
	};

	function patchRow(id: number, patch: Partial<Row>) {
		setRows((prev) => prev.map((r) => (r.manga.id === id ? { ...r, ...patch } : r)));
	}

	function pickSource(id: number | null) {
		setSourceId(id);
		setSelected(new Set());
		setStep('series');
	}

	async function toggleAllSeries() {
		if (!libraryQuery.hasNextPage && selected.size === series.length) {
			setSelected(new Set());
			return;
		}
		setSelectingAll(true);
		try {
			let data = libraryQuery.data;
			let more = libraryQuery.hasNextPage;
			while (more) {
				const page = await libraryQuery.fetchNextPage({ cancelRefetch: false, throwOnError: true });
				data = page.data;
				more = page.hasNextPage;
			}
			setSelected(new Set((data?.pages.flatMap((page) => page.entries) ?? series).map((entry) => entry.id)));
		} catch {
			pushToast('Could not load the complete library selection.', 'error');
		} finally {
			setSelectingAll(false);
		}
	}

	function matchRows(items: Row[]) {
		searchRequest.current?.abort();
		const request = new AbortController();
		searchRequest.current = request;
		setMatching(true);
		void autoMatch(items, eligibleDestinations, request.signal, patchRow).finally(() => {
			if (!request.signal.aborted) setMatching(false);
		});
	}

	function startMatch() {
		if (!eligibleDestinations.length) return;
		const initial: Row[] = series.filter((entry) => selected.has(entry.id))
			.map((manga) => ({ manga, state: 'pending' }));
		setRows(initial);
		setExecuted(false);
		setStep('match');
		matchRows(initial);
	}

	const matchedRows = rows.filter((r) => r.state === 'matched' && r.target && eligibleDestinations.includes(r.target.sourceId) && !r.result?.ok);
	const failedRows = rows.filter((r) => r.result && !r.result.ok);
	const doneCount = rows.filter((r) => r.result?.ok).length;

	function execute(mode: MigrateMode) {
		const entries = matchedRows
			.filter((r) => !r.result?.ok)
			.map((r) => ({
				fromMangaId: r.manga.id,
				toSourceId: r.target!.sourceId!,
				toMangaKey: r.target!.key,
				toManga: r.target
			}));
		if (entries.length === 0) return;
		migrate.mutate(
			{ mode, entries, safePageOffsets: true },
			{
				onSuccess: (res) => {
					setExecuted(true);
					setConfirmMode(null);
					for (const item of res.results) {
						patchRow(item.fromMangaId, { result: item });
					}
					const failed = res.results.filter((r) => !r.ok).length;
					pushToast(
						failed === 0
							? t('migrate.toastDone', { count: res.results.length })
							: t('migrate.toastPartial', { done: res.results.length - failed, failed }),
						'info'
					);
					for (const item of res.results) {
						for (const w of item.warnings ?? []) pushToast(w, 'info');
					}
				}
			}
		);
	}

	return (
		<div className="page container">
			<PageHeader
				title={t('migrate.title')}
				actions={
					step !== 'source' ? (
						<Button
							size="sm"
							disabled={matching || migrate.isPending || selectingAll}
							onClick={() => incoming.length && step === 'series' ? navigate('/library') : setStep(step === 'series' ? 'source' : step === 'destinations' ? 'series' : 'destinations')}
						>
							<ArrowLeft size={14} />
							{t('migrate.back')}
						</Button>
					) : undefined
				}
			/>

			{step === 'source' &&
				(sourcesQuery.isPending ? (
					<div className="migrate-source-list">
						{Array.from({ length: 3 }, (_, i) => (
							<Skeleton key={i} height={64} style={{ borderRadius: 'var(--r-md)' }} />
						))}
					</div>
				) : (
					<>
						<p className="muted">{t('migrate.pickSourceHint')}</p>
						<div className="migrate-source-list">
							{migrateSources.some((source) => source.mangaCount > 0) && (
								<button type="button" className="migrate-source" onClick={() => pickSource(null)}>
									<span className="migrate-source__name">{t('migrate.allSources', { defaultValue: 'All library sources' })}</span>
									<span className="migrate-source__count">{t('migrate.inLibrary', { count: migrateSources.reduce((sum, source) => sum + source.mangaCount, 0) })}</span>
									<ArrowRight size={16} />
								</button>
							)}
							{migrateSources
								.filter((s) => s.mangaCount > 0)
								.map((s) => (
									<button
										key={s.id}
										type="button"
										className="migrate-source"
										onClick={() => pickSource(s.id)}
									>
										<span className="migrate-source__name">{s.name}{!s.enabled && <small className="muted"> · {t('aidokuWizard.sourceUnavailable')}</small>}</span>
										<span className="migrate-source__count">{t('migrate.inLibrary', { count: s.mangaCount })}</span>
										<ArrowRight size={16} />
									</button>
								))}
						</div>
						{migrateSources.every((s) => s.mangaCount === 0) && (
							<EmptyState icon={TriangleAlert} title={t('migrate.libraryEmpty')} hint={t('migrate.libraryEmptyHint')} />
						)}
					</>
				))}

			{step === 'series' && (
				<>
					<div className="migrate-toolbar">
						<span>
							<Trans
								i18nKey="migrate.selectedCount"
								values={{ source: sourceName, selected: selected.size, total: series.length }}
								components={{ b: <b /> }}
							/>
						</span>
						<Button size="sm" loading={selectingAll} disabled={!series.length} onClick={() => void toggleAllSeries()}>
							{!libraryQuery.hasNextPage && selected.size === series.length ? t('migrate.clearAll') : t('migrate.selectAll')}
						</Button>
						<Button size="sm" variant="primary" disabled={selected.size === 0 || selectingAll} onClick={() => setStep('destinations')}>
							{t('migrate.pickDestinations')}
							<ArrowRight size={14} />
						</Button>
					</div>
					<div className="migrate-series">
						{series.map((m) => (
							<label key={m.id} className="migrate-series__item">
								<input
									type="checkbox"
									checked={selected.has(m.id)}
									onChange={() =>
										setSelected((prev) => {
											const next = new Set(prev);
											if (next.has(m.id)) next.delete(m.id);
											else next.add(m.id);
											return next;
										})
									}
								/>
								<span className="migrate-series__cover">
									<Cover src={coverUrl(m.id, m.cover)} title={m.title} />
								</span>
								<span className="migrate-series__title">{m.title}</span>
							</label>
						))}
					</div>
					{libraryQuery.hasNextPage && (
						<Button size="sm" loading={libraryQuery.isFetchingNextPage} onClick={() => void libraryQuery.fetchNextPage()}>
							{t('migrate.loadMore')}
						</Button>
					)}
				</>
			)}

			{step === 'destinations' && (
				<>
					<DestinationPicker selected={destinations} onChange={setDestinations} originSourceId={sourceId} />
					<div className="migrate-toolbar">
						<Button variant="primary" disabled={eligibleDestinations.length === 0} onClick={startMatch}>
							{t('migrate.startMatch', { count: selected.size })}
							<ArrowRight size={14} />
						</Button>
					</div>
				</>
			)}

			{step === 'match' && (
				<>
					<div className="migrate-toolbar">
						<span>
							{t('migrate.status', {
								dests: destinations.map(destName).join(' → '),
								matched: matchedRows.length,
								total: rows.length,
								matching: matching ? t('migrate.statusMatching') : '',
								executed: executed ? t('migrate.statusExecuted', { done: doneCount }) : ''
							})}
						</span>
						{matching && <Spinner size={16} />}
						{executed && failedRows.length > 0 && <Button size="sm" onClick={() => setExecuted(false)}>{t('aidokuWizard.retryFailed', { defaultValue: 'Retry failed transfers' })}</Button>}
						{!matching && !executed && (
							<>
								<Button size="sm" onClick={() => matchRows(rows.filter((r) => r.state === 'notfound'))}>
									{t('migrate.retryUnmatched')}
								</Button>
								{(['copy', 'migrateWithHistory'] as MigrateMode[]).map((mode) => (
									<Button
										key={mode}
										size="sm"
										variant={mode === 'migrateWithHistory' ? 'primary' : undefined}
										disabled={matchedRows.length === 0}
										onClick={() => setConfirmMode(mode)}
									>
										{MODE_LABEL[mode]}
									</Button>
								))}
							</>
						)}
					</div>
					<div className="migrate-rows">
						{rows.map((row) => (
							<div key={row.manga.id} className="migrate-row">
								<span className="migrate-row__cover">
									<Cover src={coverUrl(row.manga.id, row.manga.cover)} title={row.manga.title} />
								</span>
								<div className="migrate-row__side">
									<div className="migrate-row__title">{row.manga.title}</div>
									<div className="migrate-row__meta">{destName(row.manga.sourceId)}</div>
								</div>
								<ArrowRight size={16} className="migrate-row__arrow" />
								<div className="migrate-row__side">
									{row.state === 'matching' || (matching && row.state === 'pending') ? (
										<Spinner size={16} />
									) : row.target ? (
										<>
											<div className="migrate-row__title">{row.target.title}</div>
											<div className="migrate-row__meta">{destName(row.target.sourceId!)}</div>
										</>
									) : (
										<div className="migrate-row__notfound">{t('aidokuWizard.noConfidentMatch', { defaultValue: 'No confident match — choose manually' })}</div>
									)}
									{row.result &&
										(row.result.ok ? (
											<Link className="migrate-row__goto" to={`/manga/${row.result.toMangaId}`}>
												{t('migrate.gotoTarget')}
											</Link>
										) : (
											<Reason item={row.result} />
										))}
									{(row.result?.warnings ?? []).map((warning) => <p className="muted" key={warning}>{warning}</p>)}
								</div>
								{!executed && !matching && !row.result?.ok && (
									<RowMenu
										onRematch={() => setRematchRow(row)}
										onRemove={() => setRows((prev) => prev.filter((r) => r.manga.id !== row.manga.id))}
									/>
								)}
							</div>
						))}
					</div>
				</>
			)}

			<Modal
				open={confirmMode !== null}
				title={confirmMode ? t('migrate.confirmTitle', { mode: MODE_LABEL[confirmMode], count: matchedRows.length }) : ''}
				onClose={() => setConfirmMode(null)}
				footer={
					<>
						<Button onClick={() => setConfirmMode(null)}>{t('common.cancel')}</Button>
						<Button
							variant="primary"
							loading={migrate.isPending}
							onClick={() => confirmMode && execute(confirmMode)}
						>
							{t('migrate.confirmAction', { mode: confirmMode ? MODE_LABEL[confirmMode] : '' })}
						</Button>
					</>
				}
			>
				<p className="muted">{confirmMode ? MODE_HINT[confirmMode] : ''}</p>
				<p className="muted">{t('aidokuWizard.safeTransferHelp', { defaultValue: 'Move replaces the library entry. Unmatched history stays with the original manga outside the library.' })}</p>
				<p className="muted">{t('migrate.unmatchedUntouched', { count: rows.length - matchedRows.length })}</p>
			</Modal>

			{rematchRow && (
				<RematchModal
					row={rematchRow}
					destinations={eligibleDestinations}
					destName={destName}
					onPick={(candidate) => {
						patchRow(rematchRow.manga.id, { state: 'matched', target: candidate, result: undefined });
						setRematchRow(null);
					}}
					onClose={() => setRematchRow(null)}
				/>
			)}
		</div>
	);
}

function RowMenu({ onRematch, onRemove }: { onRematch: () => void; onRemove: () => void }) {
	const { t } = useTranslation();
	// MenuButton portals the popover with a measured viewport flip, so the last row's menu
	// never crosses the screen edge; outside presses and Escape close it like every other menu
	return (
		<MenuButton label={t('migrate.moreActions')}>
			{(close) => (
				<>
					<button
						type="button"
						className="menu-row"
						onClick={() => {
							close();
							onRematch();
						}}
					>
						{t('migrate.rematch')}
					</button>
					<button
						type="button"
						className="menu-row"
						onClick={() => {
							close();
							onRemove();
						}}
					>
						{t('migrate.skipEntry')}
					</button>
				</>
			)}
		</MenuButton>
	);
}

/** Manual rematch of a single row: title-search all target sources with 3-way concurrency, user picks the candidate */
function RematchModal({
	row,
	destinations,
	destName,
	onPick,
	onClose
}: {
	row: Row;
	destinations: number[];
	destName: (id: number) => string;
	onPick: (candidate: SearchManga) => void;
	onClose: () => void;
}) {
	const { t } = useTranslation();
	const [query, setQuery] = useState(row.manga.title);
	const [searching, setSearching] = useState(false);
	const [results, setResults] = useState<SearchManga[] | null>(row.candidates ?? null);
	const [failedSources, setFailedSources] = useState(row.failedSources ?? []);
	const searchRequest = useRef<AbortController | null>(null);
	useEffect(() => () => searchRequest.current?.abort(), []);

	async function search() {
		if (!query.trim()) return;
		searchRequest.current?.abort();
		const request = new AbortController();
		searchRequest.current = request;
		setSearching(true);
		setResults(null);
		const { candidates, failures } = await searchDestinations(row.manga, destinations, request.signal, query);
		if (request.signal.aborted) return;
		setResults(candidates);
		setFailedSources(failures);
		setSearching(false);
	}

	return (
		<Modal open title={t('migrate.rematchTitle', { title: row.manga.title })} onClose={onClose} panelClassName="migrate-rematch">
			<div className="migrate-rematch__bar">
				<Input
					icon={<Search size={15} />}
					value={query}
					onChange={(e) => setQuery(e.currentTarget.value)}
					onKeyDown={(e) => e.key === 'Enter' && void search()}
				/>
				<Button size="sm" variant="primary" loading={searching} disabled={!query.trim()} onClick={() => void search()}>
					{t('common.search')}
				</Button>
			</div>
			{!searching && failedSources.length > 0 && <p role="status">{t('migrate.searchFailed', {
				defaultValue: 'Search incomplete: {{sources}} could not be checked.',
				sources: failedSources.map(destName).join(', ')
			})}</p>}
			{searching ? (
				<Spinner />
			) : results === null ? (
				<p className="muted">{t('migrate.rematchHint')}</p>
			) : results.length === 0 ? (
				<p className="muted">{t('migrate.rematchNoHits')}</p>
			) : (
				<div className="migrate-rematch__list">
					{results.map((c) => (
						<button key={`${c.sourceId}:${c.key}`} type="button" className="migrate-rematch__item" onClick={() => onPick(c)}>
							<Cover src={c.id === undefined ? c.cover : coverUrl(c.id, c.cover)} title={c.title} />
							<span className="migrate-rematch__title">{c.title}</span>
							<span className="migrate-rematch__source">{destName(c.sourceId!)}</span>
						</button>
					))}
				</div>
			)}
		</Modal>
	);
}
