import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { TFunction } from 'i18next';
import {
	Copy,
	Download,
	ExternalLink,
	FileUp,
	RotateCw,
	Trash2,
	Upload
} from 'lucide-react';
import { ApiError, api, backupUrl } from '../../api/client';
import {
	qk,
	queryClient,
	useApiKeys,
	useBackupFiles,
	useChapterCacheStats,
	useClearChapterCache,
	useClearCoverCache,
	useClearSourceChapterCache,
	useCoverCacheStats,
	useCreateApiKey,
	useImportAidoku,
	useImportSuwayomi,
	useRestoreBackup,
	useRestoreNamedBackup,
	useRevokeApiKey,
	useSaveServerSettings,
	useServerSettings,
	mergeServerSettings,
	useSources,
	useWhoami
} from '../../api/hooks';
import type {
	AidokuImportResponse,
	AidokuSkipped,
	ApiKeyCreated,
	ApiKeyEntry,
	AuthStatus,
	BackupFile,
	BackupRestoreResponse,
	SuwayomiImportResponse,
	SuwayomiSkipped,
	SuwayomiSourceReport
} from '../../api/types';
import { formatBytes } from '../../lib/format';
import { useTheme } from '../../lib/theme';
import type { Theme } from '../../lib/theme';
import { LANGUAGE_OPTIONS, setLanguage, translateApiError } from '../../i18n';
import type { Language } from '../../i18n';
import { compareVersions } from '../../lib/version';
import {
	Button,
	IconButton,
	Input,
	Modal,
	SegmentedControl,
	Select,
	Skeleton,
	Switch,
	pushToast
} from '../../components';
import { chapterCacheLimitBytes } from './chapterCache';
import { ChapterCacheSources } from './ChapterCacheSources';
import { ExcludedCategoriesSetting } from './ExcludedCategoriesSetting';
import { SkippedItems } from './SkippedItems';
import '../settings.css';
import { Section } from './SettingsSection';
import { AidokuSourceRecovery } from './AidokuSourceRecovery';
import { useAidokuImportSession } from './AidokuImportSession';

const READER_MODE_KEY = 'sumidoku.reader.mode';
const READER_DIR_KEY = 'sumidoku.reader.dir';
const READER_LAYOUT_KEY = 'sumidoku.reader.layout';
const READER_TAPZONES_KEY = 'sumidoku.reader.tapzones';
const READER_BG_KEY = 'sumidoku.reader.bg';
const READER_SCALE_KEY = 'sumidoku.reader.scale';
const READER_STRETCH_KEY = 'sumidoku.reader.stretch';
const READER_SPLIT_KEY = 'sumidoku.reader.split';
const READER_ANIM_KEY = 'sumidoku.reader.anim';
const READER_TRANSITION_KEY = 'sumidoku.reader.transition';

function stored(key: string, fallback: string): string {
	try {
		return localStorage.getItem(key) ?? fallback;
	} catch {
		return fallback;
	}
}

export function AppearanceSection() {
	const { t, i18n } = useTranslation();
	const [theme, setTheme] = useTheme();
	return (
		<Section title={t('settings.appearanceTitle')} desc={t('settings.appearanceDesc')}>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.language')}</span>
				<Select
					value={i18n.language}
					onChange={(value) => setLanguage(value as Language)}
				>
					{LANGUAGE_OPTIONS.map((option) => (
						<option key={option.value} value={option.value}>
							{option.label}
						</option>
					))}
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.theme')}</span>
				<SegmentedControl<Theme>
					options={[
						{ value: 'system', label: t('settings.themeSystem') },
						{ value: 'dark', label: t('settings.themeDark') },
						{ value: 'light', label: t('settings.themeLight') }
					]}
					value={theme}
					onChange={setTheme}
				/>
			</div>
		</Section>
	);
}

export function ReaderSection() {
	const { t } = useTranslation();
	// The old settings page stored "scroll" as vertical, while the reader only knows continuous; normalize on read
	const [mode, setMode] = useState(() => {
		const m = stored(READER_MODE_KEY, 'paged');
		return m === 'vertical' ? 'continuous' : m;
	});
	const [dir, setDir] = useState(() => stored(READER_DIR_KEY, 'ltr'));
	const [layout, setLayout] = useState(() => {
		// Same whitelist as the reader's readLayout: unknown values fall back to single
		const l = stored(READER_LAYOUT_KEY, 'single');
		return l === 'double' || l === 'doubleNoCover' ? l : 'single';
	});
	const [tapZones, setTapZones] = useState(() => {
		// Same whitelist as the reader's parseTapZones: unknown values fall back to lr
		const z = stored(READER_TAPZONES_KEY, 'lr');
		return z === 'rl' || z === 'edge' || z === 'kindle' || z === 'off' ? z : 'lr';
	});
	const [bg, setBg] = useState(() => {
		// Same whitelist as the reader's parseBackground: unknown values fall back to dark
		const b = stored(READER_BG_KEY, 'dark');
		return b === 'gray' || b === 'light' || b === 'auto' ? b : 'dark';
	});
	const [scale, setScale] = useState(() => {
		// Same whitelist as the reader's parseScale: unknown values fall back to screen
		const s = stored(READER_SCALE_KEY, 'screen');
		return s === 'width' || s === 'widthShrink' || s === 'height' || s === 'original' ? s : 'screen';
	});
	const [stretch, setStretch] = useState(() => stored(READER_STRETCH_KEY, '0') === '1');
	const [split, setSplit] = useState(() => stored(READER_SPLIT_KEY, '0') === '1');
	// The animation defaults to on, so only "0" disables it
	const [anim, setAnim] = useState(() => stored(READER_ANIM_KEY, '1') !== '0');
	// The chapter transition page also defaults to on, so only "0" disables it
	const [transition, setTransition] = useState(() => stored(READER_TRANSITION_KEY, '1') !== '0');

	function persist(key: string, value: string, apply: (v: string) => void) {
		apply(value);
		try {
			localStorage.setItem(key, value);
		} catch {
			// Private mode blocks the write but the setting still switches, just without persisting
		}
	}

	return (
		<Section title={t('settings.readerSectionTitle')} desc={t('settings.readerSectionDesc')}>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerMode')}</span>
				<Select
					value={mode}
					onChange={(value) => persist(READER_MODE_KEY, value, setMode)}
				>
					<option value="paged">{t('settings.modePaged')}</option>
					<option value="continuous">{t('settings.modeContinuous')}</option>
					<option value="webtoon">{t('settings.modeWebtoon')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerDirection')}</span>
				<Select value={dir} onChange={(value) => persist(READER_DIR_KEY, value, setDir)}>
					<option value="ltr">{t('settings.dirLtr')}</option>
					<option value="rtl">{t('settings.dirRtl')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerLayout')}</span>
				<Select value={layout} onChange={(value) => persist(READER_LAYOUT_KEY, value, setLayout)}>
					<option value="single">{t('settings.layoutSingle')}</option>
					<option value="double">{t('settings.layoutDouble')}</option>
					<option value="doubleNoCover">{t('settings.layoutDoubleNoCover')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerTapZones')}</span>
				<Select value={tapZones} onChange={(value) => persist(READER_TAPZONES_KEY, value, setTapZones)}>
					<option value="lr">{t('settings.tzLr')}</option>
					<option value="rl">{t('settings.tzRl')}</option>
					<option value="edge">{t('settings.tzEdge')}</option>
					<option value="kindle">{t('settings.tzKindle')}</option>
					<option value="off">{t('settings.tzOff')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerBackground')}</span>
				<Select value={bg} onChange={(value) => persist(READER_BG_KEY, value, setBg)}>
					<option value="dark">{t('settings.bgDark')}</option>
					<option value="gray">{t('settings.bgGray')}</option>
					<option value="light">{t('settings.bgLight')}</option>
					<option value="auto">{t('settings.bgAuto')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerPageScale')}</span>
				<Select value={scale} onChange={(value) => persist(READER_SCALE_KEY, value, setScale)}>
					<option value="screen">{t('settings.scaleScreen')}</option>
					<option value="width">{t('settings.scaleWidth')}</option>
					<option value="widthShrink">{t('settings.scaleWidthShrink')}</option>
					<option value="height">{t('settings.scaleHeight')}</option>
					<option value="original">{t('settings.scaleOriginal')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerStretch')}</span>
				<Select
					value={stretch ? '1' : '0'}
					onChange={(value) => persist(READER_STRETCH_KEY, value, (v) => setStretch(v === '1'))}
				>
					<option value="0">{t('settings.stretchOff')}</option>
					<option value="1">{t('settings.stretchOn')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerSplitWide')}</span>
				<Select
					value={split ? '1' : '0'}
					onChange={(value) => persist(READER_SPLIT_KEY, value, (v) => setSplit(v === '1'))}
				>
					<option value="0">{t('settings.stretchOff')}</option>
					<option value="1">{t('settings.stretchOn')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerAnimations')}</span>
				<Select
					value={anim ? '1' : '0'}
					onChange={(value) => persist(READER_ANIM_KEY, value, (v) => setAnim(v === '1'))}
				>
					<option value="0">{t('settings.stretchOff')}</option>
					<option value="1">{t('settings.stretchOn')}</option>
				</Select>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.readerTransition')}</span>
				<Select
					value={transition ? '1' : '0'}
					onChange={(value) => persist(READER_TRANSITION_KEY, value, (v) => setTransition(v === '1'))}
				>
					<option value="0">{t('settings.stretchOff')}</option>
					<option value="1">{t('settings.stretchOn')}</option>
				</Select>
			</div>
		</Section>
	);
}

export function IncognitoSection() {
	const { t } = useTranslation();
	const settings = useServerSettings();
	const save = useSaveServerSettings();
	const enabled = settings.data?.incognito.enabled === true;

	return (
		<Section
			title={t('settings.incognitoTitle')}
			desc={t('settings.incognitoDesc')}
		>
			{settings.isPending ? (
				<Skeleton height={48} />
			) : (
				<label className="settings-backup__section">
					<Switch
						checked={enabled}
						disabled={save.isPending}
						onChange={(on) =>
							save.mutate(mergeServerSettings(settings.data, { incognito: { enabled: on } }))
						}
						label={t('settings.incognitoGlobal')}
					/>
					{t('settings.incognitoGlobal')}
				</label>
			)}
		</Section>
	);
}

export function ChapterCacheSection() {
	const { t } = useTranslation();
	const settings = useServerSettings();
	const save = useSaveServerSettings();
	const stats = useChapterCacheStats();
	const clear = useClearChapterCache();
	const clearSource = useClearSourceChapterCache();
	const [clearConfirm, setClearConfirm] = useState(false);
	const [sourceConfirm, setSourceConfirm] = useState<number | null>(null);
	const cacheSettings = settings.data?.cache;
	const maxBytes = cacheSettings?.chapterMaxBytes ?? 2 * 1024 ** 3;
	const [maxMiB, setMaxMiB] = useState(String(maxBytes / 1024 ** 2));
	useEffect(() => setMaxMiB(String(maxBytes / 1024 ** 2)), [maxBytes]);

	async function saveLimit() {
		const value = chapterCacheLimitBytes(maxMiB);
		if (value === null) {
			setMaxMiB(String(maxBytes / 1024 ** 2));
			return;
		}
		if (value === maxBytes || !settings.data) return;
		try {
			await save.mutateAsync(
				mergeServerSettings(settings.data, {
					cache: { chapterMaxBytes: value }
				})
			);
		} catch {
			setMaxMiB(String(maxBytes / 1024 ** 2));
		}
	}

	async function clearCache() {
		try {
			const result = await clear.mutateAsync();
			pushToast(t('settings.chapterCacheCleared', { size: formatBytes(result.clearedBytes) }), 'info');
			setClearConfirm(false);
		} catch {
			// The API client already reports the error; keep the confirmation open for retry.
		}
	}

	async function clearSourceCache(sourceId: number) {
		try {
			const result = await clearSource.mutateAsync(sourceId);
			pushToast(t('settings.chapterCacheCleared', { size: formatBytes(result.clearedBytes) }), 'info');
			setSourceConfirm(null);
		} catch {
			// The API client already reports the error; keep the confirmation open for retry.
		}
	}

	const confirmSource = stats.data?.sources.find((source) => source.sourceId === sourceConfirm);

	return (
		<Section title={t('settings.chapterCacheTitle')} desc={t('settings.chapterCacheDesc')}>
			{settings.isPending || stats.isPending ? (
				<Skeleton height={48} />
			) : settings.isError || stats.isError || !settings.data || !stats.data ? (
				<div>
					<p className="settings-backup__warn">{t('settings.chapterCacheLoadFailed')}</p>
					<Button
						disabled={settings.isFetching || stats.isFetching}
						loading={settings.isFetching || stats.isFetching}
						onClick={() => {
							void settings.refetch();
							void stats.refetch();
						}}
					>
						{t('settings.retry')}
					</Button>
				</div>
			) : (
				<>
					<div className="settings-row">
						<label className="settings-row__label" htmlFor="chapter-cache-limit">
							{t('settings.chapterCacheLimit')}
						</label>
						<Input
							id="chapter-cache-limit"
							type="number"
							min={0}
							step={1}
							value={maxMiB}
							disabled={save.isPending}
							onChange={(event) => setMaxMiB(event.currentTarget.value)}
							onBlur={() => void saveLimit()}
							onKeyDown={(event) => {
								if (event.key === 'Enter') event.currentTarget.blur();
							}}
						/>
						<span className="faint">MiB</span>
					</div>
					<p className="faint">
						{t('settings.chapterCacheUsage', {
							used: formatBytes(stats.data?.usedBytes ?? 0),
							count: stats.data?.chapterCount ?? 0
						})}
					</p>
					{stats.data && (
						<p className="faint">
							{t('settings.chapterCacheBreakdown', {
								pages: formatBytes(stats.data.breakdown.pageBytes),
								originals: formatBytes(stats.data.breakdown.originalBytes),
								blobs: formatBytes(stats.data.breakdown.blobBytes),
								opds: formatBytes(stats.data.breakdown.opdsBytes)
							})}
						</p>
					)}
					{stats.data?.lastError && (
						<p className="settings-backup__warn">
							{t('settings.chapterCacheError', { error: stats.data.lastError })}
						</p>
					)}
					<Button variant="danger" disabled={clear.isPending} onClick={() => setClearConfirm(true)}>
						{t('settings.clearChapterCache')}
					</Button>
					{stats.data && (
						<ChapterCacheSources
							sources={stats.data.sources}
							clearing={clearSource.isPending}
							onClear={setSourceConfirm}
						/>
					)}
				</>
			)}
			<Modal
				open={clearConfirm}
				title={t('settings.clearChapterCache')}
				onClose={() => {
					if (!clear.isPending) setClearConfirm(false);
				}}
				footer={
					<>
						<Button disabled={clear.isPending} onClick={() => setClearConfirm(false)}>
							{t('common.cancel')}
						</Button>
						<Button variant="danger" loading={clear.isPending} onClick={() => void clearCache()}>
							{t('settings.clearChapterCache')}
						</Button>
					</>
				}
			>
				<p className="settings-modal-text">{t('settings.clearChapterCacheConfirm')}</p>
			</Modal>
			<Modal
				open={sourceConfirm !== null}
				title={t('settings.clearSourceChapterCache')}
				onClose={() => {
					if (!clearSource.isPending) setSourceConfirm(null);
				}}
				footer={
					<>
						<Button disabled={clearSource.isPending} onClick={() => setSourceConfirm(null)}>
							{t('common.cancel')}
						</Button>
						<Button
							variant="danger"
							loading={clearSource.isPending}
							onClick={() => {
								if (sourceConfirm !== null) void clearSourceCache(sourceConfirm);
							}}
						>
							{t('settings.clearSourceChapterCache')}
						</Button>
					</>
				}
			>
				<p className="settings-modal-text">
					{t('settings.clearSourceChapterCacheConfirm', { name: confirmSource?.sourceName ?? '' })}
				</p>
			</Modal>
		</Section>
	);
}

export function CoverCacheSection() {
	const { t } = useTranslation();
	const stats = useCoverCacheStats();
	const clear = useClearCoverCache();
	const [clearConfirm, setClearConfirm] = useState(false);

	async function clearCache() {
		try {
			const result = await clear.mutateAsync();
			pushToast(
				t('settings.coverCacheCleared', {
					size: formatBytes(result.clearedBytes),
					count: result.clearedEntries
				}),
				'info'
			);
			setClearConfirm(false);
		} catch {
			// The API client already reports the error; keep the confirmation open for retry.
		}
	}

	return (
		<Section title={t('settings.coverCacheTitle')} desc={t('settings.coverCacheDesc')}>
			{stats.isPending ? (
				<Skeleton height={48} />
			) : stats.isError || !stats.data ? (
				<div>
					<p className="settings-backup__warn">{t('settings.coverCacheLoadFailed')}</p>
					<Button
						disabled={stats.isFetching}
						loading={stats.isFetching}
						onClick={() => void stats.refetch()}
					>
						{t('settings.retry')}
					</Button>
				</div>
			) : (
				<>
					<p className="faint">
						{t('settings.coverCacheUsage', {
							entries: stats.data.entries,
							max: stats.data.maxEntries,
							size: formatBytes(stats.data.usedBytes)
						})}
					</p>
					<Button variant="danger" disabled={clear.isPending} onClick={() => setClearConfirm(true)}>
						{t('settings.clearCoverCache')}
					</Button>
				</>
			)}
			<Modal
				open={clearConfirm}
				title={t('settings.clearCoverCache')}
				onClose={() => {
					if (!clear.isPending) setClearConfirm(false);
				}}
				footer={
					<>
						<Button disabled={clear.isPending} onClick={() => setClearConfirm(false)}>
							{t('common.cancel')}
						</Button>
						<Button variant="danger" loading={clear.isPending} onClick={() => void clearCache()}>
							{t('settings.clearCoverCache')}
						</Button>
					</>
				}
			>
				<p className="settings-modal-text">{t('settings.clearCoverCacheConfirm')}</p>
			</Modal>
		</Section>
	);
}

export function SecuritySection() {
	const { t } = useTranslation();
	const navigate = useNavigate();
	const whoami = useWhoami();
	const [current, setCurrent] = useState('');
	const [next, setNext] = useState('');
	const [pending, setPending] = useState(false);

	async function submit() {
		if (!current || !next || pending) return;
		setPending(true);
		try {
			// Changing the password revokes all session tokens, so success forces a re-login
			await api('/auth/password', {
				method: 'PUT',
				body: { currentPassword: current, newPassword: next },
				silent: true
			});
			pushToast(t('settings.passwordChanged'), 'info');
				navigate('/login');
		} catch (e) {
			pushToast(e instanceof ApiError && e.status === 401 ? t('settings.wrongPassword') : t('settings.changeFailed'));
		} finally {
			setPending(false);
		}
	}

	async function logout() {
		await api('/auth/logout', { method: 'POST', silent: true }).catch(() => {});
		queryClient.setQueryData(qk.whoami, (cur: AuthStatus | undefined) =>
			cur ? { ...cur, user: null } : cur
		);
		navigate('/login');
	}

	const enabled = whoami.data === undefined ? null : whoami.data.enabled;
	const user = whoami.data?.user ?? null;

	return (
		<Section title={t('settings.securityTitle')} desc={t('settings.securityDesc')}>
			{enabled === null ? (
				<Skeleton height={48} />
			) : !enabled ? (
				<p className="faint settings-security__off">
					{t('settings.authDisabled')}
				</p>
			) : (
				<>
					{user && (
						<div className="settings-row">
							<span className="settings-row__label">{t('settings.currentAccount')}</span>
							<span className="settings-security__account">
								{user.username}
							</span>
						</div>
					)}
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.currentPassword')}</span>
						<Input
							type="password"
							value={current}
							onChange={(e) => setCurrent(e.currentTarget.value)}
						/>
					</div>
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.newPassword')}</span>
						<Input
							type="password"
							value={next}
							onChange={(e) => setNext(e.currentTarget.value)}
						/>
					</div>
					<div className="settings-security__ops">
						<Button
							variant="primary"
							loading={pending}
							disabled={!current || !next}
							onClick={() => void submit()}
						>
							{t('settings.changePassword')}
						</Button>
						<Button onClick={() => void logout()}>{t('settings.logout')}</Button>
					</div>
				</>
			)}
		</Section>
	);
}

function fmtTime(unix: number | null): string {
	return unix === null ? '' : new Date(unix * 1000).toLocaleString();
}

export function ApiKeysSection() {
	const { t } = useTranslation();
	const keys = useApiKeys();
	const create = useCreateApiKey();
	const revoke = useRevokeApiKey();
	const [newName, setNewName] = useState('');
	const [created, setCreated] = useState<ApiKeyCreated | null>(null);
	const [revoking, setRevoking] = useState<ApiKeyEntry | null>(null);

	const entries = keys.data ?? [];

	function toastError(e: unknown) {
		if (e instanceof ApiError) pushToast(translateApiError(e.code, e.message));
		else pushToast(e instanceof Error ? e.message : t('settings.operationFailed'));
	}

	async function submitCreate() {
		const name = newName.trim();
		if (create.isPending || !name) return;
		try {
			const entry = await create.mutateAsync(name);
			setNewName('');
			setCreated(entry);
		} catch (e) {
			toastError(e);
		}
	}

	function dismissCreated() {
		create.reset();
		setCreated(null);
	}

	async function copyCreated() {
		if (!created) return;
		try {
			await navigator.clipboard.writeText(created.key);
			pushToast(t('settings.keyCopied'), 'info');
		} catch {
			pushToast(t('settings.operationFailed'));
		}
	}

	return (
		<Section title={t('settings.apiKeysTitle')} desc={t('settings.apiKeysDesc')}>
			{keys.isPending ? (
				<div className="settings-cats">
					<Skeleton height={48} />
				</div>
			) : (
				<div className="settings-cats">
					{entries.map((entry) => (
						<div key={entry.id} className="settings-cat">
							<div className="settings-cat__head">
								<span className="settings-cat__name">{entry.name}</span>
								<span className="settings-cat__ops">
									<IconButton
										label={t('settings.revoke')}
										size="sm"
										variant="danger"
										onClick={() => setRevoking(entry)}
									>
										<Trash2 size={15} />
									</IconButton>
								</span>
							</div>
							{entry.createdAt !== null && (
								<p className="faint">
									{t('settings.createdAt')} {fmtTime(entry.createdAt)}
									{' · '}
									{t('settings.lastUsed')}{' '}
									{entry.lastUsedAt === null ? t('settings.never') : fmtTime(entry.lastUsedAt)}
								</p>
							)}
						</div>
					))}
				</div>
			)}

			<div className="settings-cat__create">
				<Input
					placeholder={t('settings.apiKeyNamePlaceholder')}
					value={newName}
					disabled={create.isPending}
					onChange={(e) => setNewName(e.currentTarget.value)}
					onKeyDown={(e) => {
						if (e.key === 'Enter') void submitCreate();
					}}
				/>
				<Button
					variant="primary"
					loading={create.isPending}
					disabled={create.isPending || !newName.trim()}
					onClick={() => void submitCreate()}
				>
					{t('settings.createApiKey')}
				</Button>
			</div>

			<Modal
				open={created !== null}
				title={t('settings.apiKeyCreatedTitle')}
				onClose={dismissCreated}
				footer={<Button variant="primary" onClick={dismissCreated}>{t('settings.done')}</Button>}
			>
				<p className="settings-modal-text">{t('settings.apiKeyCreatedHint')}</p>
				<div className="settings-cat__create">
					<Input readOnly value={created?.key ?? ''} onFocus={(e) => e.currentTarget.select()} />
					<Button onClick={() => void copyCreated()}>
						<Copy size={15} />
						{t('settings.copyKey')}
					</Button>
				</div>
			</Modal>

			<Modal
				open={revoking !== null}
				title={t('settings.revoke')}
				onClose={() => setRevoking(null)}
				footer={
					<>
						<Button onClick={() => setRevoking(null)}>{t('common.cancel')}</Button>
						<Button
							variant="danger"
							loading={revoke.isPending}
							onClick={() => {
								if (!revoking) return;
								revoke.mutate(revoking.id, {
									onSuccess: () => {
										setRevoking(null);
										pushToast(t('settings.deleted'), 'info');
									},
									onError: toastError
								});
							}}
						>
							{t('settings.revoke')}
						</Button>
					</>
				}
			>
				<p className="settings-modal-text">
					{t('settings.revokeApiKeyConfirm', { name: revoking?.name })}
				</p>
			</Modal>
		</Section>
	);
}

const LIBRARY_UPDATE_INTERVALS = [
	{ hours: 0, labelKey: 'settings.libraryUpdateNever' },
	{ hours: 12, labelKey: 'settings.libraryUpdate12Hours' },
	{ hours: 24, labelKey: 'settings.libraryUpdateDaily' },
	{ hours: 48, labelKey: 'settings.libraryUpdate2Days' },
	{ hours: 168, labelKey: 'settings.libraryUpdateWeekly' }
];
const LIBRARY_SKIP_RULES = [
	{ key: 'hasUnread', labelKey: 'settings.librarySkipHasUnread' },
	{ key: 'completed', labelKey: 'settings.librarySkipCompleted' },
	{ key: 'notStarted', labelKey: 'settings.librarySkipNotStarted' }
];

function DownloadNumberInput({
	value,
	min,
	disabled,
	onCommit
}: {
	value: number;
	min: number;
	disabled: boolean;
	onCommit: (value: number) => void;
}) {
	const { t } = useTranslation();
	const [text, setText] = useState(String(value));
	useEffect(() => setText(String(value)), [value]);

	function commit() {
		const parsed = Number(text);
		if (text.trim() === '' || !Number.isInteger(parsed) || parsed < min) {
			pushToast(t('settings.minInteger', { min }));
			setText(String(value));
			return;
		}
		setText(String(parsed));
		if (parsed !== value) onCommit(parsed);
	}

	return (
		<Input
			className="settings-backup__num"
			type="number"
			min={min}
			value={text}
			disabled={disabled}
			onChange={(e) => setText(e.currentTarget.value)}
			onBlur={commit}
			onKeyDown={(e) => {
				if (e.key === 'Enter') e.currentTarget.blur();
			}}
		/>
	);
}

const DOWNLOAD_SWITCHES = [
	{ key: 'autoDownloadNewChapters', labelKey: 'settings.autoDownloadNewChapters', fallback: false },
	{ key: 'autoSkipMangaWithUnread', labelKey: 'settings.downloadSkipUnread', fallback: true },
	{ key: 'autoIgnoreReuploads', labelKey: 'settings.downloadIgnoreReuploads', fallback: false },
	{ key: 'deleteAfterManualRead', labelKey: 'settings.deleteAfterManualRead', fallback: false },
	{ key: 'deleteAfterRead', labelKey: 'settings.deleteAfterRead', fallback: false },
	{ key: 'allowDeleteBookmarked', labelKey: 'settings.allowDeleteBookmarked', fallback: false },
	{ key: 'downloadAhead', labelKey: 'settings.downloadAhead', fallback: false }
] as const;

export function DownloadSection() {
	const { t } = useTranslation();
	const settings = useServerSettings();
	const save = useSaveServerSettings();
	const data = settings.data?.download;

	return (
		<Section title={t('settings.download')} desc={t('settings.downloadDesc')}>
			{settings.isPending ? (
				<Skeleton height={320} />
			) : (
				<>
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.downloadFormat')}</span>
						<Select
							value={data?.downloadFormat ?? 'cbz'}
							disabled={save.isPending}
							onChange={(value) =>
								save.mutate(
									mergeServerSettings(settings.data, {
										download: { downloadFormat: value as 'cbz' | 'folder' }
									})
								)
							}
						>
							<option value="cbz">{t('settings.downloadFormatCbz')}</option>
							<option value="folder">{t('settings.downloadFormatFolder')}</option>
						</Select>
					</div>
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.downloadConcurrency')}</span>
						<DownloadNumberInput
							value={data?.downloadConcurrency ?? 3}
							min={1}
							disabled={save.isPending}
							onCommit={(value) =>
								save.mutate(mergeServerSettings(settings.data, { download: { downloadConcurrency: value } }))
							}
						/>
					</div>
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.autoDownloadLimit')}</span>
						<DownloadNumberInput
							value={data?.autoDownloadLimit ?? 5}
							min={0}
							disabled={save.isPending}
							onCommit={(value) =>
								save.mutate(mergeServerSettings(settings.data, { download: { autoDownloadLimit: value } }))
							}
						/>
					</div>
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.downloadAheadCount')}</span>
						<DownloadNumberInput
							value={data?.downloadAheadCount ?? 2}
							min={0}
							disabled={save.isPending}
							onCommit={(value) =>
								save.mutate(mergeServerSettings(settings.data, { download: { downloadAheadCount: value } }))
							}
						/>
					</div>
					{DOWNLOAD_SWITCHES.map(({ key, labelKey, fallback }) => (
						<label key={key} className="settings-backup__section">
							<Switch
								checked={(data?.[key] ?? fallback) === true}
								disabled={save.isPending}
								onChange={(on) =>
									save.mutate(mergeServerSettings(settings.data, { download: { [key]: on } }))
								}
								label={t(labelKey)}
							/>
							{t(labelKey)}
						</label>
					))}
					<ExcludedCategoriesSetting
						kind="download"
						title={t('settings.excludedDownloadCategories')}
						description={t('settings.excludedDownloadCategoriesDesc')}
					/>
				</>
			)}
		</Section>
	);
}

export function LibraryUpdateSection() {
	const { t } = useTranslation();
	const settings = useServerSettings();
	const save = useSaveServerSettings();
	const intervalHours = Number(settings.data?.library.updateIntervalHours ?? 0);
	const skipTitles = settings.data?.library.skipTitles ?? [];
	const refreshMetadata = settings.data?.library.refreshMetadata === true;

	function saveSkip(rule: string, on: boolean) {
		const changed = on ? [...skipTitles, rule] : skipTitles.filter((value) => value !== rule);
		const ordered = LIBRARY_SKIP_RULES.map(({ key }) => key).filter((key) => changed.includes(key));
		save.mutate(mergeServerSettings(settings.data, { library: { skipTitles: ordered } }));
	}

	return (
		<Section title={t('settings.libraryUpdateTitle')} desc={t('settings.libraryUpdateDesc')}>
			{settings.isPending ? (
				<Skeleton height={180} />
			) : (
				<>
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.libraryUpdateInterval')}</span>
						<Select
							value={String(intervalHours)}
							disabled={save.isPending}
							onChange={(value) => {
								save.mutate(
									mergeServerSettings(settings.data, { library: { updateIntervalHours: Number(value) } })
								);
							}}
						>
							{LIBRARY_UPDATE_INTERVALS.map(({ hours, labelKey }) => (
								<option key={hours} value={hours}>
									{t(labelKey)}
								</option>
							))}
							{!LIBRARY_UPDATE_INTERVALS.some(({ hours }) => hours === intervalHours) && (
								<option value={intervalHours}>
									{t('settings.libraryUpdateCustom', { hours: intervalHours })}
								</option>
							)}
						</Select>
					</div>
					{LIBRARY_SKIP_RULES.map(({ key, labelKey }) => (
						<label key={key} className="settings-backup__section">
							<Switch
								checked={skipTitles.includes(key)}
								disabled={save.isPending}
								onChange={(on) => saveSkip(key, on)}
								label={t(labelKey)}
							/>
							{t(labelKey)}
						</label>
					))}
					<label className="settings-backup__section">
						<Switch
							checked={refreshMetadata}
							disabled={save.isPending}
							onChange={(on) =>
								save.mutate(mergeServerSettings(settings.data, { library: { refreshMetadata: on } }))
							}
							label={t('settings.libraryRefreshMetadata')}
						/>
						{t('settings.libraryRefreshMetadata')}
					</label>
					<ExcludedCategoriesSetting
						kind="update"
						title={t('settings.libraryExcludedUpdateCategories')}
						description={t('settings.libraryExcludedUpdateCategoriesDesc')}
					/>
				</>
			)}
		</Section>
	);
}

const BACKUP_SECTIONS = [
	{ key: 'library', labelKey: 'settings.backupLibrary' },
	{ key: 'categories', labelKey: 'settings.backupCategories' },
	{ key: 'progress', labelKey: 'settings.backupProgress' },
	{ key: 'settings', labelKey: 'settings.backupSettings' },
	{ key: 'sourceSettings', labelKey: 'settings.backupSourceSettings' }
] as const;

interface BackupPreview {
	doc: unknown;
	createdAt: number | null;
	counts: Record<string, number>;
}

function previewCounts(doc: Record<string, unknown>): Record<string, number> {
	const count = (key: string): number => {
		const v = doc[key];
		if (Array.isArray(v)) return v.length;
		if (v && typeof v === 'object') return Object.keys(v).length;
		return 0;
	};
	const sourceSettings = doc['sourceSettings'];
	const credentialCount =
		sourceSettings && typeof sourceSettings === 'object'
			? Object.values(sourceSettings).reduce(
					(n, v) => n + (v && typeof v === 'object' ? Object.keys(v).length : 0),
					0
				)
			: 0;
	return {
		library: count('library'),
		categories: count('categories'),
		progress: count('progress'),
		settings: count('settings'),
		sourceSettings: credentialCount
	};
}

function BackupResultView({ result }: { result: BackupRestoreResponse }) {
	const { t } = useTranslation();
	return (
		<div className="settings-backup__result">
			<p className="settings-modal-text">
				{t('settings.restored', {
					library: result.restored.library,
					categories: result.restored.categories,
					progress: result.restored.progress,
					settings: result.restored.settings,
					sourceSettings: result.restored.sourceSettings
				})}
			</p>
			{result.warnings.length === 0 ? (
				<p className="faint">{t('settings.restoredAll')}</p>
			) : (
				<>
					<p className="settings-modal-text">{t('settings.skippedItems')}</p>
					<ul className="settings-backup__warnings">
						{result.warnings.map((w, i) => (
							<li key={i}>{w}</li>
						))}
					</ul>
				</>
			)}
		</div>
	);
}

function aidokuSkippedLabel(t: TFunction, s: AidokuSkipped): string {
	const what =
		s.section === 'library'
			? t('settings.libraryEntry')
			: s.section === 'trackers'
				? t('settings.trackerEntry')
				: t('settings.progressEntry');
	const chapter = s.chapterKey ? t('settings.chapterSuffix', { key: s.chapterKey }) : '';
	return `${what} ${s.sourceKey}/${s.mangaKey}${chapter}: ${s.reason}`;
}

function AidokuImportResultView({ result }: { result: AidokuImportResponse }) {
	const { t } = useTranslation();
	return (
		<div className="settings-backup__result">
			<p className="settings-modal-text">
				{t('settings.importedWithTrackers', {
					library: result.imported.library,
					categories: result.imported.categories,
					progress: result.imported.progress,
					trackers: result.imported.trackers
				})}
			</p>
			{result.skipped.length === 0 ? (
				<p className="faint">{t('settings.importedAll')}</p>
			) : (
				<SkippedItems
					label={t('settings.skippedItemsCount', { count: result.skipped.length })}
					description="Entries below were skipped for the reported reasons."
					items={result.skipped.map((s) => aidokuSkippedLabel(t, s))}
				/>
			)}
		</div>
	);
}

function suwayomiSkippedLabel(t: TFunction, s: SuwayomiSkipped): string {
	const what =
		s.section === 'library'
			? t('settings.libraryEntry')
			: s.section === 'trackers'
				? t('settings.trackerEntry')
				: t('settings.progressEntry');
	const name = s.mihonSourceName || t('settings.sourceId', { id: s.mihonSourceId });
	return `${what} ${name}/${s.mangaKey}`;
}

function suwayomiGroupName(t: TFunction, g: SuwayomiSourceReport): string {
	return g.mihonSourceName || t('settings.unknownSource', { id: g.mihonSourceId });
}

/** Mapping dropdown for an unmatched group: same-name candidates first, then the other installed sources; left empty the whole group is skipped */
function SuwayomiMappingSelect({
	group,
	value,
	onChange
}: {
	group: SuwayomiSourceReport;
	value: string;
	onChange: (key: string) => void;
}) {
	const { t } = useTranslation();
	const sources = useSources();
	const candidateKeys = new Set(group.candidates.map((c) => c.key));
	const rest = (sources.data ?? []).filter((s) => !candidateKeys.has(s.key));
	return (
		<Select value={value} onChange={onChange}>
			<option value="">{t('settings.skipSource')}</option>
			{group.candidates.map((c) => (
				<option key={c.key} value={c.key}>
					{t('settings.sourceOption', { name: c.name, key: c.key })}
				</option>
			))}
			{rest.map((s) => (
				<option key={s.key} value={s.key}>
					{t('settings.sourceOption', { name: s.name, key: s.key })}
				</option>
			))}
		</Select>
	);
}

function SuwayomiImportResultView({ result }: { result: SuwayomiImportResponse }) {
	const { t } = useTranslation();
	return (
		<div className="settings-backup__result">
			<p className="settings-modal-text">
				{t('settings.importedWithTrackers', {
					library: result.imported.library,
					categories: result.imported.categories,
					progress: result.imported.progress,
					trackers: result.imported.trackers
				})}
			</p>
			<p className="settings-modal-text">
				{result.sources
					.map((g) => {
						const label = suwayomiGroupName(t, g);
						if (g.match === 'unmatched') return t('settings.groupUnmapped', { name: label, count: g.mangaCount });
						const how = g.match === 'auto' ? t('settings.matchAuto') : t('settings.matchManual');
						return t('settings.groupMapped', {
							name: label,
							count: g.mangaCount,
							how,
							target: g.aidokuSourceName ?? g.aidokuSourceKey
						});
					})
					.join(t('settings.listSeparator'))}
			</p>
			<SkippedItems
				label={t('settings.skippedItemsCount', { count: result.skipped.length })}
				items={result.skipped.map((s) => suwayomiSkippedLabel(t, s))}
			/>
		</div>
	);
}

export function BackupSection() {
	const navigate = useNavigate();
	const { aib, setAib, result: aibResult, setResult: setAibResult, paused: aibPaused, setPaused: setAibPaused, acceptSkips, setAcceptSkips, selected, setSelected } = useAidokuImportSession();
	const { t } = useTranslation();
	const restore = useRestoreBackup();
	const fileRef = useRef<HTMLInputElement>(null);
	const [preview, setPreview] = useState<BackupPreview | null>(null);
	const [picked, setPicked] = useState<string[]>([]);
	const [result, setResult] = useState<BackupRestoreResponse | null>(null);
	const importAidoku = useImportAidoku();
	const aibFileRef = useRef<HTMLInputElement>(null);
	const importSuwayomi = useImportSuwayomi();
	const swFileRef = useRef<HTMLInputElement>(null);
	const [sw, setSw] = useState<{ file: File; preview: SuwayomiImportResponse } | null>(null);
	const [swMapping, setSwMapping] = useState<Record<string, string>>({});
	const [swResult, setSwResult] = useState<SuwayomiImportResponse | null>(null);
	const sections = BACKUP_SECTIONS;

	async function onSwFile(e: React.ChangeEvent<HTMLInputElement>) {
		const file = e.currentTarget.files?.[0];
		e.currentTarget.value = '';
		if (!file) return;
		try {
			const preview = await importSuwayomi.mutateAsync({ file, dryRun: true });
			setSw({ file, preview });
			setSwMapping({});
			setSwResult(null);
		} catch {
			// api() already popped an error toast
		}
	}

	function setSwSource(mihonId: string, key: string) {
		setSwMapping((cur) => {
			const next = { ...cur };
			if (key) next[mihonId] = key;
			else delete next[mihonId];
			return next;
		});
	}

	async function confirmSwImport() {
		if (!sw) return;
		try {
			const res = await importSuwayomi.mutateAsync({ file: sw.file, dryRun: false, mapping: swMapping });
			setSwResult(res);
		} catch {
			// api() already popped an error toast
		}
	}

	function closeSwModal() {
		setSw(null);
		setSwMapping({});
		setSwResult(null);
	}

	async function onAibFile(e: React.ChangeEvent<HTMLInputElement>) {
		const file = e.currentTarget.files?.[0];
		e.currentTarget.value = '';
		if (!file) return;
		try {
			const dryPreview = await importAidoku.mutateAsync({ file, dryRun: true });
			setAib({ file, preview: dryPreview });
			setSelected([]);
			setAibPaused(false); setAcceptSkips(false);
			setAibResult(null);
		} catch {
			// api() already popped an error toast
		}
	}

	async function confirmAibImport() {
		if (!aib || (aib.preview.skipped.length > 0 && !acceptSkips)) return;
		try {
			const res = await importAidoku.mutateAsync({ file: aib.file, dryRun: false });
			setAibResult(res);
		} catch {
			// api() already popped an error toast
		}
	}

	function closeAibModal() {
		setAib(null);
		setAibResult(null);
		setSelected([]);
	}

	async function onFile(e: React.ChangeEvent<HTMLInputElement>) {
		const file = e.currentTarget.files?.[0];
		// Clear value so picking the same file again still fires change
		e.currentTarget.value = '';
		if (!file) return;
		let doc: unknown;
		try {
			doc = JSON.parse(await file.text());
		} catch {
			pushToast(t('settings.invalidBackupJson'));
			return;
		}
		const version = (doc as { version?: unknown } | null)?.version;
		if (version !== 1) {
			pushToast(t('settings.unsupportedBackupVersion', { version: typeof version === 'number' ? version : t('settings.versionMissing') }));
			return;
		}
		const createdAt = (doc as { createdAt?: unknown }).createdAt;
		setPreview({
			doc,
			createdAt: typeof createdAt === 'number' ? createdAt : null,
			counts: previewCounts(doc as Record<string, unknown>)
		});
		setPicked(sections.map((s) => s.key));
		setResult(null);
	}

	function toggle(key: string, on: boolean) {
		setPicked((cur) => (on ? [...cur, key] : cur.filter((k) => k !== key)));
	}

	async function confirmRestore() {
		if (!preview || picked.length === 0) return;
		try {
			const res = await restore.mutateAsync({ doc: preview.doc, sections: picked });
			setResult(res);
		} catch {
			// api() already popped an error toast
		}
	}

	function closeModal() {
		setPreview(null);
		setResult(null);
	}

	return (
		<Section
			title={t('settings.backupTitle')}
			desc={t('settings.backupDesc')}
		>
			<div className="settings-backup__ops">
				<a className="btn settings-backup__download" href={backupUrl()} download>
					<Download size={15} />
					{t('settings.downloadBackup')}
				</a>
				<Button onClick={() => fileRef.current?.click()}>
					<Upload size={15} />
					{t('settings.uploadBackup')}
				</Button>
				<input
					ref={fileRef}
					type="file"
					accept="application/json,.json"
					hidden
					onChange={(e) => void onFile(e)}
				/>
				{aibPaused && aib && <Button onClick={() => { setAibPaused(false); void importAidoku.mutateAsync({ file: aib.file, dryRun: true }).then((preview) => { setAib((current) => current?.file === aib.file ? { ...current, preview } : current); setAcceptSkips(false); }).catch(() => {}); }}>Resume Aidoku Import</Button>}
				<Button loading={importAidoku.isPending && !aib} onClick={() => aibFileRef.current?.click()}>
					<FileUp size={15} />
					{t('settings.importAidoku')}
				</Button>
				<input
					ref={aibFileRef}
					type="file"
					accept=".aib"
					hidden
					onChange={(e) => void onAibFile(e)}
				/>
				<Button loading={importSuwayomi.isPending && !sw} onClick={() => swFileRef.current?.click()}>
					<FileUp size={15} />
					{t('settings.importSuwayomi')}
				</Button>
				<input
					ref={swFileRef}
					type="file"
					accept=".tachibk,.gz,.proto"
					hidden
					onChange={(e) => void onSwFile(e)}
				/>
			</div>

			<Modal
				open={sw !== null}
				title={t('settings.importSuwayomi')}
				onClose={closeSwModal}
				footer={
					swResult ? (
						<Button variant="primary" onClick={closeSwModal}>
							{t('settings.done')}
						</Button>
					) : (
						<>
							<Button onClick={closeSwModal}>{t('common.cancel')}</Button>
							<Button variant="primary" loading={importSuwayomi.isPending} onClick={() => void confirmSwImport()}>
								{t('settings.confirmImport')}
							</Button>
						</>
					)
				}
			>
				{swResult ? (
					<SuwayomiImportResultView result={swResult} />
				) : (
					sw && (
						<>
							<p className="settings-modal-text">
								{t('settings.willImportWithTrackers', {
									library: sw.preview.imported.library,
									categories: sw.preview.imported.categories,
									progress: sw.preview.imported.progress,
									trackers: sw.preview.imported.trackers
								})}
							</p>
							<p className="settings-modal-text">{t('settings.sourceMapping')}</p>
							<ul className="settings-backup__mapping">
								{sw.preview.sources.map((g) => (
									<li key={g.mihonSourceId} className="settings-backup__mapping-row">
										<span className="settings-backup__mapping-name">
											{t('settings.groupWithCount', { name: suwayomiGroupName(t, g), count: g.mangaCount })}
										</span>
										{g.match === 'unmatched' ? (
											<SuwayomiMappingSelect
												group={g}
												value={swMapping[g.mihonSourceId] ?? ''}
												onChange={(key) => setSwSource(g.mihonSourceId, key)}
											/>
										) : (
											<span className="faint">{t('settings.autoMatched', { name: g.aidokuSourceName ?? g.aidokuSourceKey })}</span>
										)}
									</li>
								))}
							</ul>
							{sw.preview.skipped.length > 0 && (
								<p className="settings-modal-text">
									{t('settings.unmappedSkipped', { count: sw.preview.skipped.length })}
								</p>
							)}
							<p className="settings-backup__warn">
								{t('settings.importMergeWarnSuwayomi')}
							</p>
						</>
					)
				)}
			</Modal>

			<Modal
				open={!aibPaused && aib !== null}
				title={t('settings.importAidoku')}
				onClose={closeAibModal}
				footer={
					aibResult ? (
						<Button variant="primary" onClick={closeAibModal}>
							{t('settings.done')}
						</Button>
					) : (
						<>
							<Button onClick={closeAibModal}>{t('common.cancel')}</Button>
							<Button variant="primary" loading={importAidoku.isPending} disabled={!!aib?.preview.skipped.length && !acceptSkips} onClick={() => void confirmAibImport()}>
								{t('settings.confirmImport')}
							</Button>
						</>
					)
				}
			>
				{aibResult ? (
					<AidokuImportResultView result={aibResult} />
				) : (
					aib && (
						<>
							<p className="settings-modal-text">
								{t('settings.willImportWithTrackers', {
									library: aib.preview.imported.library,
									categories: aib.preview.imported.categories,
									progress: aib.preview.imported.progress,
									trackers: aib.preview.imported.trackers
								})}
							</p>
						<AidokuSourceRecovery file={aib.file} preview={aib.preview} selection={selected} onSelectionChange={setSelected} onPreview={(preview) => { setAib((current) => current?.file === aib.file ? { ...current, preview } : current); setAcceptSkips(false); }} onManageLists={() => { setAibPaused(true); navigate('/browse?view=lists'); }} />
						{aib.preview.skipped.length > 0 && <label><input type="checkbox" checked={acceptSkips} onChange={(event) => setAcceptSkips(event.currentTarget.checked)} /> I understand the exact entries and reasons below will be skipped. My original backup is retained.</label>}
							<SkippedItems
								label={t('settings.willSkipItemsCount', { count: aib.preview.skipped.length })}
								description="Every skipped entry is listed with its exact reason. Keep the original backup."
								items={aib.preview.skipped.map((s) => aidokuSkippedLabel(t, s))}
							/>
							<p className="settings-backup__warn">
								{t('settings.importMergeWarn')}
							</p>
						</>
					)
				)}
			</Modal>

			<Modal
				open={preview !== null}
				title={t('settings.restoreBackup')}
				onClose={closeModal}
				footer={
					result ? (
						<Button variant="primary" onClick={closeModal}>
							{t('settings.done')}
						</Button>
					) : (
						<>
							<Button onClick={closeModal}>{t('common.cancel')}</Button>
							<Button
								variant="danger"
								loading={restore.isPending}
								disabled={picked.length === 0}
								onClick={() => void confirmRestore()}
							>
								{t('settings.import')}
							</Button>
						</>
					)
				}
			>
				{result ? (
					<BackupResultView result={result} />
				) : (
					preview && (
						<>
							<p className="settings-modal-text">
								{preview.createdAt
									? t('settings.restorePickWithDate', { date: new Date(preview.createdAt * 1000).toLocaleString() })
									: t('settings.restorePick')}
							</p>
							<div className="settings-backup__sections">
								{sections.map((s) => (
									<label key={s.key} className="settings-backup__section">
										<input
											type="checkbox"
											checked={picked.includes(s.key)}
											onChange={(e) => toggle(s.key, e.currentTarget.checked)}
										/>
										{t('settings.sectionWithCount', { name: t(s.labelKey), count: preview.counts[s.key] ?? 0 })}
									</label>
								))}
							</div>
							<p className="settings-backup__warn">
								{t('settings.restoreWarn')}
							</p>
						</>
					)
				)}
			</Modal>
		</Section>
	);
}

function formatSize(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
	return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function DownloadMoveSection() {
	const { t } = useTranslation();
	const settings = useServerSettings();
	const save = useSaveServerSettings();
	const [text, setText] = useState<string | null>(null);

	useEffect(() => {
		if (!settings.data) return;
		if (text === null) setText(settings.data.download.movePath ?? '');
	}, [settings.data, text]);

	const data = settings.data;
	if (!data || text === null) {
		return (
			<Section
				title={t('settings.downloadMoveTitle')}
				desc={t('settings.downloadMoveDescShort')}
			>
				<Skeleton height={48} />
			</Section>
		);
	}

	const current = data.download.movePath ?? '';

	function commit() {
		if (text === null) return;
		const value = text.trim();
		if (value !== current) save.mutate(mergeServerSettings(settings.data, { download: { movePath: value } }));
	}

	return (
		<Section
			title={t('settings.downloadMoveTitle')}
			desc={t('settings.downloadMoveDesc')}
		>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.moveTemplate')}</span>
				<Input
					placeholder="/mnt/library/{author}/{manga}/{filename}"
					value={text}
					disabled={save.isPending}
					onChange={(e) => setText(e.currentTarget.value)}
					onBlur={commit}
					onKeyDown={(e) => {
						if (e.key === 'Enter') commit();
					}}
				/>
			</div>
			<p className="faint settings-backup__hint">
				{t('settings.moveTemplateHint')}
			</p>
		</Section>
	);
}

export function ScheduledBackupSection() {
	const { t } = useTranslation();
	const settings = useServerSettings();
	const save = useSaveServerSettings();
	const backups = useBackupFiles();
	const restore = useRestoreNamedBackup();
	const [confirming, setConfirming] = useState<BackupFile | null>(null);
	const [result, setResult] = useState<BackupRestoreResponse | null>(null);
	const [intervalText, setIntervalText] = useState<string | null>(null);
	const [retentionText, setRetentionText] = useState<string | null>(null);

	useEffect(() => {
		if (!settings.data) return;
		if (intervalText === null) setIntervalText(String(settings.data.backup.intervalHours ?? 24));
		if (retentionText === null) setRetentionText(String(settings.data.backup.retentionCount ?? 10));
	}, [settings.data, intervalText, retentionText]);

	const data = settings.data;
	if (!data || intervalText === null || retentionText === null) {
		return (
			<Section
				title={t('settings.autoBackupTitle')}
				desc={t('settings.autoBackupDesc')}
			>
				<Skeleton height={48} />
			</Section>
		);
	}

	const enabled = data.backup.enabled === true;
	const lastRun = data.backup.lastRun;
	const files = backups.data?.files ?? [];

	function commitNumber(
		key: 'intervalHours' | 'retentionCount',
		text: string,
		fallback: number,
		min: number,
		reset: (v: string) => void
	) {
		const n = Number(text);
		if (!Number.isInteger(n) || n < min) {
			pushToast(t('settings.minInteger', { min }));
			reset(String(fallback));
			return;
		}
		if (n !== fallback) {
			save.mutate(mergeServerSettings(settings.data, { backup: { [key]: n } }));
		}
	}

	const intervalHours = data.backup.intervalHours ?? 24;
	const retentionCount = data.backup.retentionCount ?? 10;

	async function confirmRestore() {
		if (!confirming) return;
		try {
			const res = await restore.mutateAsync(confirming.name);
			setResult(res);
			setConfirming(null);
		} catch {
			// api() already popped an error toast
		}
	}

	function closeModal() {
		setConfirming(null);
		setResult(null);
	}

	return (
		<Section
			title={t('settings.autoBackupTitle')}
			desc={t('settings.autoBackupDesc')}
		>
			<label className="settings-backup__section">
				<input
					type="checkbox"
					checked={enabled}
					onChange={(e) =>
						save.mutate(mergeServerSettings(settings.data, { backup: { enabled: e.currentTarget.checked } }))
					}
				/>
				{t('settings.enableAutoBackup')}
			</label>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.backupInterval')}</span>
				<Input
					className="settings-backup__num"
					type="number"
					min={1}
					value={intervalText}
					onChange={(e) => setIntervalText(e.currentTarget.value)}
					onBlur={() =>
						commitNumber('intervalHours', intervalText, intervalHours, 1, setIntervalText)
					}
					onKeyDown={(e) => {
						if (e.key === 'Enter')
							commitNumber('intervalHours', intervalText, intervalHours, 1, setIntervalText);
					}}
				/>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.retentionCount')}</span>
				<Input
					className="settings-backup__num"
					type="number"
					min={0}
					value={retentionText}
					onChange={(e) => setRetentionText(e.currentTarget.value)}
					onBlur={() =>
						commitNumber('retentionCount', retentionText, retentionCount, 0, setRetentionText)
					}
					onKeyDown={(e) => {
						if (e.key === 'Enter')
							commitNumber(
								'retentionCount',
								retentionText,
								retentionCount,
								0,
								setRetentionText
							);
					}}
				/>
			</div>
			<div className="settings-row">
				<span className="settings-row__label">{t('settings.backupDir')}</span>
				<span className="settings-backup__dir">{backups.data?.dir ?? '…'}</span>
			</div>
			<p className="faint settings-backup__hint">
				{t('settings.backupDirHint', {
					lastRun: typeof lastRun === 'number' ? new Date(lastRun * 1000).toLocaleString() : t('settings.never')
				})}
			</p>

			<div className="settings-backup__files-head">
				<span className="settings-row__label">{t('settings.existingBackups')}</span>
				<IconButton label={t('settings.refresh')} size="sm" onClick={() => void backups.refetch()}>
					<RotateCw size={14} />
				</IconButton>
			</div>
			{files.length === 0 ? (
				<p className="faint">{t('settings.noBackups')}</p>
			) : (
				<div className="settings-backup__files">
					{files.map((f) => (
						<div key={f.name} className="settings-backup__file">
							<div className="settings-backup__file-meta">
								<span>{new Date(f.createdAt * 1000).toLocaleString()}</span>
								<span className="faint">{formatSize(f.size)}</span>
							</div>
							<Button size="sm" onClick={() => setConfirming(f)}>
								{t('settings.restore')}
							</Button>
						</div>
					))}
				</div>
			)}

			<Modal
				open={confirming !== null || result !== null}
				title={t('settings.restoreBackup')}
				onClose={closeModal}
				footer={
					result ? (
						<Button variant="primary" onClick={closeModal}>
							{t('settings.done')}
						</Button>
					) : (
						<>
							<Button onClick={closeModal}>{t('common.cancel')}</Button>
							<Button variant="danger" loading={restore.isPending} onClick={() => void confirmRestore()}>
								{t('settings.restore')}
							</Button>
						</>
					)
				}
			>
				{result ? (
					<BackupResultView result={result} />
				) : (
					confirming && (
						<>
							<p className="settings-modal-text">
								{t('settings.restoreNamedConfirm', { date: new Date(confirming.createdAt * 1000).toLocaleString() })}
							</p>
							<p className="settings-backup__warn">
								{t('settings.backupTrustWarn')}
							</p>
						</>
					)
				)}
			</Modal>
		</Section>
	);
}

export function AboutSection() {
	const { t } = useTranslation();
	const [version, setVersion] = useState<string | null>(null);
	const [latest, setLatest] = useState<{ tag: string; url: string } | null>(null);
	useEffect(() => {
		let cancelled = false;
		(async () => {
			let v: string;
			try {
				v = (await api<{ version: string }>('/version', { silent: true })).version;
			} catch {
				return;
			}
			if (cancelled) return;
			setVersion(v);

		})();
		return () => {
			cancelled = true;
		};
	}, []);
	async function checkServerRelease() {
        try {
            const response = await fetch('https://api.github.com/repos/Sumidoku/Sumidoku/releases/latest');
            if (!response.ok) throw new Error('Release service unavailable');
            const release = await response.json() as { tag_name?: string; html_url?: string };
            if (release.tag_name && release.html_url) setLatest({ tag: release.tag_name, url: release.html_url });
        } catch { pushToast('Server release information is unavailable. The installed server is unchanged.'); }
    }

	const newer = version && latest ? compareVersions(latest.tag, version) : null;
	const update = newer !== null && newer > 0 ? latest : null;
	const upToDate = newer !== null && newer <= 0;
	return (
		<Section title={t('settings.aboutTitle')} desc={t('settings.aboutDesc')}>
			<div className="settings-about">
				<Button onClick={() => void checkServerRelease()}>Check upstream server release</Button>
				<p>
					<strong>Sumidoku</strong> · {t('settings.tagline')}
				</p>
				<p className="muted">
					{t('settings.endpoints')}
					{' · '}
					<a
						className="setting-link"
						href="/api/docs"
						target="_blank"
						rel="noreferrer"
					>
						{t('settings.apiDocs')}
						<ExternalLink size={13} />
					</a>
				</p>
				{version && (
					<p className="muted">
						{t('settings.currentVersion', { version })}
						{update && (
							<>
								{' · '}
								<a className="setting-link" href={update.url} target="_blank" rel="noreferrer">
									{t('settings.newVersion', { tag: update.tag })}
									<ExternalLink size={13} />
								</a>
							</>
						)}
						{upToDate && ` · ${t('settings.upToDate')}`}
					</p>
				)}
				<a
					className="setting-link"
					href="https://github.com/Sumidoku/Sumidoku"
					target="_blank"
					rel="noreferrer"
				>
					GitHub
					<ExternalLink size={13} />
				</a>
			</div>
		</Section>
	);
}

