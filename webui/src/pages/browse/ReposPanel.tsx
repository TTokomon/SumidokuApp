import { useEffect, useMemo, useState } from 'react';
import { ChevronDown, ChevronUp, CircleArrowUp, Download, Globe, Plus, RefreshCw, Search, Trash } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
	useDeleteSourceRepo,
	useInstallRepoSource,
	useRenameSourceRepo,
	useRefreshSourceRepo,
	useRepoSources,
	useSourceRepos,
	useUpdateSource
} from '../../api/hooks';
import type { RepoSource, SourceRepo } from '../../api/types';
import { relativeTime } from '../../lib/format';
import { loadRepoLangs, saveRepoLangs } from '../../lib/repoPrefs';
import {
	CONTENT_RATING_LEVELS,
	MULTI_LANGUAGE,
	compareLanguageLabel,
	contentRatingColor,
	contentRatingLabel,
	isMultiLanguage,
	languageLabel
} from '../../lib/source';
import {
	Button,
	Chip,
	EmptyState,
	IconButton,
	Input,
	Modal,
	Skeleton,
	Switch,
	pushToast
} from '../../components';
import { iconColor } from './iconColor';
import { repoTitle } from './AddRepoModal';

const COLLAPSED_COUNT = 3;

function EntryIcon({ entry }: { entry: RepoSource }) {
	const [failed, setFailed] = useState(false);
	if (!entry.iconUrl || failed) {
		return (
			<span className="source-card__icon-fallback" style={{ background: iconColor(entry.key) }}>
				{entry.name.slice(0, 1)}
			</span>
		);
	}
	return (
		<span className="source-card__icon">
			<img
				src={entry.iconUrl}
				alt=""
				loading="lazy"
				referrerPolicy="no-referrer"
				onError={() => setFailed(true)}
			/>
		</span>
	);
}

function EntryAction({ entry }: { entry: RepoSource }) {
	const { t } = useTranslation();
	const install = useInstallRepoSource();
	const update = useUpdateSource();
	const navigate = useNavigate();
	const busy = install.isPending || update.isPending;

	async function onClick() {
		try {
			if (entry.installedId !== null && entry.updateVersion !== null) {
				const r = await update.mutateAsync(entry.installedId);
				pushToast(t('reposPanel.updated', { name: entry.name, version: r.version }), 'info');
				for (const w of r.migrationWarnings.slice(0, 3)) pushToast(w, 'info');
				if (r.migrationRequired) {
					pushToast(t('reposPanel.migrationRequired', { name: entry.name }), 'info');
					navigate(`/migrate?source=${entry.installedId}&sameSource=1`);
				}
			} else if (entry.installedId === null) {
				await install.mutateAsync({ repoId: entry.repoId, sourceKey: entry.key });
				pushToast(t('reposPanel.installed', { name: entry.name }), 'info');
			}
		} catch {
			// client already popped an error toast
		}
	}

	if (entry.installedId !== null && entry.updateVersion !== null) {
		return (
			<Button variant="primary" loading={busy} onClick={() => void onClick()}>
				<CircleArrowUp size={15} />
				{t('reposPanel.update', { version: entry.updateVersion })}
			</Button>
		);
	}
	if (entry.installedId !== null) {
		return <Button disabled>{t('reposPanel.installedVersion', { version: entry.installedVersion })}</Button>;
	}
	return (
		<Button variant="primary" loading={busy} onClick={() => void onClick()}>
			<Download size={15} />
			{t('reposPanel.install')}
		</Button>
	);
}

function RepoList({
	repos,
	onRefresh,
	onDelete,
	onRename,
	refreshPending
}: {
	repos: SourceRepo[];
	onRefresh: (r: SourceRepo) => void;
	onDelete: (r: SourceRepo) => void;
	onRename: (r: SourceRepo) => void;
	refreshPending: boolean;
}) {
	const { t } = useTranslation();
	return (
		<div className="source-list">
			{repos.map((r) => (
				<div key={r.id} className="source-card">
					<div className="source-card__main">
						<div className="source-card__name">
							<span className="source-card__name-text">{repoTitle(r.url, r.name)}</span>
							{r.fetchError && <Chip color="danger">{t('reposPanel.syncFailed')}</Chip>}
						</div>
						<div className="source-card__meta">
							{r.url} · {t('reposPanel.sourceCount', { count: r.sourceCount })}
							{r.fetchedAt ? t('reposPanel.fetchedAt', { time: relativeTime(r.fetchedAt) }) : ''}
						</div>
					</div>
					<Button onClick={() => onRename(r)}>Rename</Button>
					<IconButton
						label={t('reposPanel.refresh', { name: repoTitle(r.url, r.name) })}
						onClick={() => onRefresh(r)}
						disabled={refreshPending}
					>
						<RefreshCw size={16} />
					</IconButton>
					<IconButton
						label={t('reposPanel.delete', { name: repoTitle(r.url, r.name) })}
						variant="danger"
						onClick={() => onDelete(r)}
					>
						<Trash size={17} />
					</IconButton>
				</div>
			))}
		</div>
	);
}

export default function ReposPanel({ manage = true }: { manage?: boolean }) {
	const { t } = useTranslation();
	const repos = useSourceRepos();
	const delRepo = useDeleteSourceRepo();
	const refreshRepo = useRefreshSourceRepo();
	const [pendingDelete, setPendingDelete] = useState<SourceRepo | null>(null);
	const [expanded, setExpanded] = useState(false);
	const rename = useRenameSourceRepo();
	const batch = useInstallRepoSource();
	const [renameTarget, setRenameTarget] = useState<SourceRepo | null>(null);
	const [renameName, setRenameName] = useState('');
	const [uninstallSources, setUninstallSources] = useState(false);
	const [selected, setSelected] = useState<string[]>([]);
	const [batchConfirm, setBatchConfirm] = useState(false);
	const [batchReport, setBatchReport] = useState('');

	const [query, setQuery] = useState('');
	const [repoFilter, setRepoFilter] = useState('');
	const [langs, setLangs] = useState<string[]>(loadRepoLangs);
	const [ratings, setRatings] = useState<number[]>(() =>
		CONTENT_RATING_LEVELS.map((level) => level.value)
	);
	const [langOpen, setLangOpen] = useState(false);

	// 500ms search debounce, same as in-source search
	const [submitted, setSubmitted] = useState('');
	useEffect(() => {
		const t = setTimeout(() => setSubmitted(query.trim()), 500);
		return () => clearTimeout(t);
	}, [query]);

	useEffect(() => {
		saveRepoLangs(langs);
	}, [langs]);

	const hasRepos = (repos.data ?? []).length > 0;
	const entries = useRepoSources(
		{
			langs,
			query: submitted || undefined,
			// selecting all three levels equals no filtering; selecting none sends an empty string and the server matches the empty set
			contentRating:
				ratings.length === CONTENT_RATING_LEVELS.length ? undefined : ratings.join(',')
		},
		hasRepos
	);
	// Language candidates derive from the unfiltered full list; deriving from filtered results would filter the options themselves away
	const allEntries = useRepoSources({}, hasRepos);
	const langOptions = useMemo(() => {
		const set = new Set<string>();
		for (const e of allEntries.data ?? []) {
			for (const l of e.languages) {
				const code = l.trim().toLowerCase();
				if (code && !isMultiLanguage(code)) set.add(code);
			}
		}
		// Same as Aidoku: the multi-language sentinel always sits at the top of the list
		return [MULTI_LANGUAGE, ...[...set].sort(compareLanguageLabel)];
	}, [allEntries.data]);

	function toggleLang(code: string) {
		setLangs((prev) => (prev.includes(code) ? prev.filter((c) => c !== code) : [...prev, code]));
	}

	function toggleRating(value: number) {
		setRatings((prev) =>
			prev.includes(value)
				? prev.filter((v) => v !== value)
				: [...prev, value].sort((a, b) => a - b)
		);
	}

	async function onRefresh(repo: SourceRepo) {
		try {
			await refreshRepo.mutateAsync(repo.id);
			pushToast(t('reposPanel.repoRefreshed', { name: repoTitle(repo.url, repo.name) }), 'info');
		} catch {
			// On failure the repo row's fetchError is already stored; after the list refetches it carries the stale mark
		}
	}

	async function confirmDelete() {
		if (!pendingDelete) return;
		try {
			await delRepo.mutateAsync({ id: pendingDelete.id, uninstallSources });
			pushToast(t('reposPanel.repoDeleted', { name: repoTitle(pendingDelete.url, pendingDelete.name) }), 'info');
			setPendingDelete(null);
		} catch {
			// client already popped an error toast
		}
	}

	const filteredEntries = (entries.data ?? []).filter((entry) => !repoFilter || String(entry.repoId) === repoFilter);
	const selectedEntries = filteredEntries.filter((entry) => selected.includes(`${entry.repoId}:${entry.key}`) && entry.installedId === null);
	async function installSelected() {
		const failures: string[] = [];
		for (const entry of selectedEntries) {
			try { await batch.mutateAsync({ repoId: entry.repoId, sourceKey: entry.key }); }
			catch { failures.push(`${entry.repoId}:${entry.key}`); }
		}
		setSelected(failures); setBatchConfirm(false);
		setBatchReport(failures.length ? `Some sources could not be installed: ${failures.join(', ')}. Completed installs were kept; retry the remaining selections.` : 'Selected sources installed. No chapters downloaded.');
	}
	return (
		<div className="repos">
			{repos.isPending ? (
				<div className="source-list">
					{Array.from({ length: 2 }, (_, i) => (
						<Skeleton key={i} height={64} style={{ borderRadius: 'var(--r-md)' }} />
					))}
				</div>
			) : !hasRepos ? (
				<EmptyState
					icon={Plus}
					title={t('reposPanel.noRepos')}
					hint={t('reposPanel.noReposHint')}
				/>
			) : (
				<>
					{manage && <RepoList
						repos={(repos.data ?? []).slice(0, expanded ? undefined : COLLAPSED_COUNT)}
						onRefresh={onRefresh}
						onDelete={(repo) => { setUninstallSources(false); setPendingDelete(repo); }}
						onRename={(repo) => { setRenameTarget(repo); setRenameName(repoTitle(repo.url, repo.name)); }}
						refreshPending={refreshRepo.isPending}
					/>}
					{manage && (repos.data ?? []).length > COLLAPSED_COUNT && (
						<button
							type="button"
							className="repos__expand"
							onClick={() => setExpanded((v) => !v)}
						>
							{expanded ? (
								<>
									<ChevronUp size={15} />
									{t('reposPanel.collapse')}
								</>
							) : (
								<>
									<ChevronDown size={15} />
									{t('reposPanel.expandAll', { count: (repos.data ?? []).length - COLLAPSED_COUNT })}
								</>
							)}
						</button>
					)}

					{selectedEntries.length > 0 && <Button onClick={() => setBatchConfirm(true)}>Install selected sources ({selectedEntries.length})…</Button>}
					{batchReport && <p role="status">{batchReport}</p>}
					<div className="repos__filters">
						<label>Source List <select aria-label="Source List" value={repoFilter} onChange={(e) => { setRepoFilter(e.currentTarget.value); setSelected([]); }}>
							<option value="">All Source Lists</option>
							{(repos.data ?? []).map((repo) => <option key={repo.id} value={repo.id}>{repoTitle(repo.url, repo.name)}</option>)}
						</select></label>
						<Input
							icon={<Search size={15} />}
							type="search"
							placeholder={t('reposPanel.searchPlaceholder')}
							value={query}
							onChange={(e) => setQuery(e.currentTarget.value)}
						/>
						<Button onClick={() => setLangOpen(true)}>
							<Globe size={15} />
							{langs.length > 0
								? t('reposPanel.languagesWithCount', { count: langs.length })
								: t('reposPanel.languages')}
						</Button>
						<div className="repos__ratings" role="group" aria-label={t('reposPanel.contentRating')}>
							{CONTENT_RATING_LEVELS.map((level) => {
								const on = ratings.includes(level.value);
								return (
									<Chip
										key={level.value}
										color={on ? level.color : 'default'}
										onClick={() => toggleRating(level.value)}
										title={on
											? t('reposPanel.hideRating', { label: level.label })
											: t('reposPanel.showRating', { label: level.label })}
									>
										{level.label}
									</Chip>
								);
							})}
						</div>
					</div>

					{entries.isPending ? (
						<div className="source-list">
							{Array.from({ length: 4 }, (_, i) => (
								<Skeleton key={i} height={82} style={{ borderRadius: 'var(--r-md)' }} />
							))}
						</div>
					) : filteredEntries.length === 0 ? (
						<EmptyState icon={Search} title={t('reposPanel.noMatch')} hint={t('reposPanel.noMatchHint')} />
					) : (
						<div className="source-list">
							{filteredEntries.map((entry) => (
								<div key={`${entry.repoId}:${entry.key}`} className="source-card">
									{entry.installedId === null && <input type="checkbox" aria-label={`Select ${entry.name} (${entry.key}) from ${entry.repoName ?? entry.repoId}`} checked={selected.includes(`${entry.repoId}:${entry.key}`)} onChange={(event) => { const checked = event.currentTarget.checked; const key = `${entry.repoId}:${entry.key}`; setSelected((old) => checked ? [...old.filter((item) => !item.endsWith(`:${entry.key}`)), key] : old.filter((item) => item !== key)); }} />}
									<EntryIcon entry={entry} />
									<div className="source-card__main">
										<div className="source-card__name">
											<span className="source-card__name-text">{entry.name}</span>
											{entry.contentRating > 0 && (
												<Chip color={contentRatingColor(entry.contentRating)}>
													{contentRatingLabel(entry.contentRating)}
												</Chip>
											)}
										</div>
										<div className="source-card__meta">
											{entry.key} · v{entry.version}
											{entry.repoName ? ` · ${entry.repoName}` : ''}
										</div>
										{entry.languages.length > 0 && (
											<div className="source-card__badges">
												{entry.languages.slice(0, 3).map((l) => (
													<Chip key={l}>{languageLabel(l)}</Chip>
												))}
												{entry.languages.length > 3 && <Chip>+{entry.languages.length - 3}</Chip>}
											</div>
										)}
									</div>
									<EntryAction entry={entry} />
								</div>
							))}
						</div>
					)}
				</>
			)}

			<Modal
				open={langOpen}
				title={t('reposPanel.selectLanguages')}
				onClose={() => setLangOpen(false)}
				footer={
					<Button variant="primary" onClick={() => setLangOpen(false)}>
						{t('reposPanel.done')}
					</Button>
				}
			>
				<div className="repos__lang-list">
					{langOptions.map((code) => (
						<label key={code} className="repos__lang-row">
							<span>{languageLabel(code)}</span>
							<Switch
								checked={langs.includes(code)}
								onChange={() => toggleLang(code)}
								label={languageLabel(code)}
							/>
						</label>
					))}
				</div>
			</Modal>

			<Modal
				open={pendingDelete !== null}
				title={t('reposPanel.deleteRepoTitle', { name: pendingDelete ? repoTitle(pendingDelete.url, pendingDelete.name) : '' })}
				onClose={() => setPendingDelete(null)}
				footer={
					<>
						<Button onClick={() => setPendingDelete(null)}>{t('common.cancel')}</Button>
						<Button variant="danger" loading={delRepo.isPending} onClick={() => void confirmDelete()}>
							{t('common.delete')}
						</Button>
					</>
				}
			>
				<p>Removing a subscription and uninstalling its packages are separate choices. Library entries, categories and reading progress are preserved in both cases.</p>
				<label><input type="radio" name="remove-list" checked={!uninstallSources} onChange={() => setUninstallSources(false)} /> Remove subscription only; keep installed sources</label>
				<label><input type="radio" name="remove-list" checked={uninstallSources} onChange={() => setUninstallSources(true)} /> Also uninstall its packages; retain library and progress for an exact-ID reinstall</label>
			</Modal>
			<Modal open={renameTarget !== null} title="Rename Source List" onClose={() => setRenameTarget(null)} footer={<Button loading={rename.isPending} onClick={() => { if (renameTarget) void rename.mutateAsync({ id: renameTarget.id, name: renameName }).then(() => setRenameTarget(null)).catch(() => {}); }}>Save Name</Button>}>
				<Input aria-label="Source list name" value={renameName} onChange={(e) => setRenameName(e.currentTarget.value)} />
			</Modal>
			<Modal open={batchConfirm} title="Install Selected Sources" onClose={() => setBatchConfirm(false)} footer={<Button loading={batch.isPending} onClick={() => void installSelected()}>Confirm Installation</Button>}>
				<p>Install only these selected packages. This does not download manga chapters.</p>
				<ul>{selectedEntries.map((entry) => <li key={`${entry.repoId}:${entry.key}`}>{entry.key} · {entry.repoName ?? entry.repoId} · v{entry.version}</li>)}</ul>
			</Modal>
		</div>
	);
}
