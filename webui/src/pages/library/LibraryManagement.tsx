import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { ArrowDown, ArrowUp, Pencil, Trash2 } from 'lucide-react';
import { ApiError } from '../../api/client';
import { useCategories, useCreateCategory, useRenameCategory, useDeleteCategory, useReorderCategories, useServerSettings, useSaveServerSettings, mergeServerSettings, useFilterGroups, useCreateFilterGroup, useUpdateFilterGroup, useDeleteFilterGroup, useReorderFilterGroups, useSources, useLibraryAuthors, useLibraryTags } from '../../api/hooks';
import type { Category, FilterGroup, FilterRule, FilterRuleType } from '../../api/types';
import type { TriStateSelection } from '../../lib/triState';
import { MANGA_CONTENT_RATING_LEVELS } from '../../lib/source';
import { translateApiError } from '../../i18n';
import { Badge, Button, IconButton, Input, Modal, SegmentedControl, Select, Skeleton, Switch, TriStateDropdown, pushToast } from '../../components';
import { Section } from '../settings/SettingsSection';
import '../settings.css';

export function CategoriesSection() {
	const { t } = useTranslation();
	const categories = useCategories();
	const create = useCreateCategory();
	const rename = useRenameCategory();
	const del = useDeleteCategory();
	const reorder = useReorderCategories();

	const [newName, setNewName] = useState('');
	const [renaming, setRenaming] = useState<Category | null>(null);
	const [renameText, setRenameText] = useState('');
	const [deleting, setDeleting] = useState<Category | null>(null);

	const cats = categories.data ?? [];

	function toastError(e: unknown) {
		if (e instanceof ApiError && e.status === 409) pushToast(t('settings.categoryExists'));
		else if (e instanceof ApiError) pushToast(translateApiError(e.code, e.message));
		else pushToast(e instanceof Error ? e.message : t('settings.operationFailed'));
	}

	async function submitCreate() {
		const name = newName.trim();
		if (!name) return;
		try {
			await create.mutateAsync(name);
			setNewName('');
			pushToast(t('settings.categoryCreated'), 'info');
		} catch (e) {
			toastError(e);
		}
	}

	async function submitRename() {
		if (!renaming) return;
		const name = renameText.trim();
		if (!name) return;
		try {
			await rename.mutateAsync({ id: renaming.id, name });
			setRenaming(null);
			pushToast(t('settings.renamed'), 'info');
		} catch (e) {
			toastError(e);
		}
	}

	function move(index: number, delta: number) {
		const ids = cats.map((c) => c.id);
		const j = index + delta;
		if (j < 0 || j >= ids.length) return;
		[ids[index], ids[j]] = [ids[j], ids[index]];
		reorder.mutate(ids);
	}

	return (
		<Section title={t('settings.categoriesTitle')} desc={t('settings.categoriesDesc')}>
			{categories.isPending ? (
				<div className="settings-cats">
					{Array.from({ length: 2 }, (_, i) => (
						<Skeleton key={i} height={72} />
					))}
				</div>
			) : (
				<div className="settings-cats">
					{cats.map((c, i) => (
						<div key={c.id} className="settings-cat">
							<div className="settings-cat__head">
								<span className="settings-cat__name">
									{c.name}
									<Badge>{c.mangaCount}</Badge>
								</span>
								<span className="settings-cat__ops">
									<IconButton
										label={t('settings.rename')}
										size="sm"
										onClick={() => {
											setRenaming(c);
											setRenameText(c.name);
										}}
									>
										<Pencil size={15} />
									</IconButton>
									<IconButton
										label={t('settings.moveUp')}
										size="sm"
										disabled={i === 0 || reorder.isPending}
										onClick={() => move(i, -1)}
									>
										<ArrowUp size={15} />
									</IconButton>
									<IconButton
										label={t('settings.moveDown')}
										size="sm"
										disabled={i === cats.length - 1 || reorder.isPending}
										onClick={() => move(i, 1)}
									>
										<ArrowDown size={15} />
									</IconButton>
									{!c.isDefault && (
										<IconButton
											label={t('settings.deleteCategory')}
											size="sm"
											variant="danger"
											onClick={() => setDeleting(c)}
										>
											<Trash2 size={15} />
										</IconButton>
									)}
								</span>
							</div>
						</div>
					))}
				</div>
			)}

			<div className="settings-cat__create">
				<Input
					placeholder={t('settings.newCategoryPlaceholder')}
					value={newName}
					onChange={(e) => setNewName(e.currentTarget.value)}
					onKeyDown={(e) => {
						if (e.key === 'Enter') void submitCreate();
					}}
				/>
				<Button
					variant="primary"
					loading={create.isPending}
					disabled={!newName.trim()}
					onClick={() => void submitCreate()}
				>
					{t('settings.createCategory')}
				</Button>
			</div>

			<Modal
				open={renaming !== null}
				title={t('settings.renameCategoryTitle')}
				onClose={() => setRenaming(null)}
				footer={
					<>
						<Button onClick={() => setRenaming(null)}>{t('common.cancel')}</Button>
						<Button
							variant="primary"
							loading={rename.isPending}
							disabled={!renameText.trim()}
							onClick={() => void submitRename()}
						>
							{t('common.save')}
						</Button>
					</>
				}
			>
				<Input
					className="settings-modal-input"
					placeholder={t('settings.categoryNamePlaceholder')}
					value={renameText}
					onChange={(e) => setRenameText(e.currentTarget.value)}
					onKeyDown={(e) => {
						if (e.key === 'Enter') void submitRename();
					}}
				/>
			</Modal>

			<Modal
				open={deleting !== null}
				title={t('settings.deleteCategory')}
				onClose={() => setDeleting(null)}
				footer={
					<>
						<Button onClick={() => setDeleting(null)}>{t('common.cancel')}</Button>
						<Button
							variant="danger"
							loading={del.isPending}
							onClick={() => {
								if (!deleting) return;
								del.mutate(deleting.id, {
									onSuccess: () => {
										setDeleting(null);
										pushToast(t('settings.deleted'), 'info');
									}
								});
							}}
						>
							{t('common.delete')}
						</Button>
					</>
				}
			>
				<p className="settings-modal-text">
					{t('settings.deleteCategoryConfirm', { name: deleting?.name })}
				</p>
			</Modal>
		</Section>
	);
}

export function LibraryDisplaySection() {
	const { t } = useTranslation();
	const settings = useServerSettings();
	const save = useSaveServerSettings();
	const categories = useCategories();

	const defaultCategory = String(settings.data?.library.defaultCategory ?? 'all');
	const showUncategorized = settings.data?.library.showUncategorized !== false;

	return (
		<Section title={t('settings.libraryTitle')} desc={t('settings.libraryDesc')}>
			{settings.isPending ? (
				<Skeleton height={72} />
			) : (
				<>
					<div className="settings-row">
						<span className="settings-row__label">{t('settings.defaultCategory')}</span>
						<Select
							value={defaultCategory}
							disabled={save.isPending}
							onChange={(value) =>
								save.mutate(
									mergeServerSettings(settings.data, { library: { defaultCategory: value } })
								)
							}
						>
							<option value="all">{t('settings.defaultCategoryAll')}</option>
							<option value="uncategorized">{t('settings.defaultCategoryUncategorized')}</option>
							{(categories.data ?? []).map((c) => (
								<option key={c.id} value={String(c.id)}>
									{c.name}
								</option>
							))}
						</Select>
					</div>
					<p className="settings-cat__hint">{t('settings.defaultCategoryHint')}</p>
					<label className="settings-backup__section">
						<Switch
							checked={showUncategorized}
							disabled={save.isPending}
							onChange={(on) =>
								save.mutate(mergeServerSettings(settings.data, { library: { showUncategorized: on } }))
							}
							label={t('settings.showUncategorized')}
						/>
						{t('settings.showUncategorized')}
					</label>
				</>
			)}
		</Section>
	);
}

type FlagRuleType = 'downloaded' | 'has_unread' | 'started' | 'completed';
const FLAG_RULE_TYPES: { type: FlagRuleType; labelKey: string }[] = [
	{ type: 'downloaded', labelKey: 'settings.ruleDownloaded' },
	{ type: 'has_unread', labelKey: 'settings.ruleHasUnread' },
	{ type: 'started', labelKey: 'settings.ruleStarted' },
	{ type: 'completed', labelKey: 'settings.ruleCompleted' }
];

/** Editor state of one group: per-flag tri-states plus the valued dimensions' tri-state selections */
interface GroupDraft {
	name: string;
	flags: Record<FlagRuleType, 0 | 1 | -1>;
	sources: TriStateSelection;
	ratings: TriStateSelection;
	categories: TriStateSelection;
	authors: TriStateSelection;
	tags: TriStateSelection;
}

const EMPTY_DRAFT: GroupDraft = {
	name: '',
	flags: { downloaded: 0, has_unread: 0, started: 0, completed: 0 },
	sources: {},
	ratings: {},
	categories: {},
	authors: {},
	tags: {}
};

/** Same tri-state cycle as the library page's chips: unselected → include → exclude → unselected */
function nextGroupTri(cur: 1 | -1 | 0): 1 | -1 | 0 {
	return cur === 0 ? 1 : cur === 1 ? -1 : 0;
}

function draftOf(group: FilterGroup): GroupDraft {
	// Every dimension needs a fresh object: a shallow copy would leave draft.sources et al. aliasing
	// EMPTY_DRAFT's, so filling the draft would pollute the next "new group" draft
	const draft: GroupDraft = {
		...EMPTY_DRAFT,
		name: group.name,
		flags: { ...EMPTY_DRAFT.flags },
		sources: {},
		ratings: {},
		categories: {},
		authors: {},
		tags: {}
	};
	for (const rule of group.rules) {
		const state = rule.exclude ? -1 : 1;
		if (rule.value === null) draft.flags[rule.type as FlagRuleType] = state;
		else if (rule.type === 'source') draft.sources[String(rule.value)] = state;
		else if (rule.type === 'content_rating') draft.ratings[String(rule.value)] = state;
		else if (rule.type === 'category') draft.categories[String(rule.value)] = state;
		else if (rule.type === 'author') draft.authors[String(rule.value)] = state;
		else if (rule.type === 'tag') draft.tags[String(rule.value)] = state;
	}
	return draft;
}

function rulesOf(draft: GroupDraft): FilterRule[] {
	const rules: FilterRule[] = [];
	for (const { type } of FLAG_RULE_TYPES) {
		const state = draft.flags[type];
		if (state !== 0) rules.push({ type, value: null, exclude: state === -1 });
	}
	const push = (type: FilterRuleType, sel: TriStateSelection) => {
		for (const [key, state] of Object.entries(sel)) {
			rules.push({ type, value: Number(key), exclude: state === -1 });
		}
	};
	// author/tag rules match by name, so the value stays the string instead of a numeric id
	const pushNames = (type: FilterRuleType, sel: TriStateSelection) => {
		for (const [key, state] of Object.entries(sel)) {
			rules.push({ type, value: key, exclude: state === -1 });
		}
	};
	push('source', draft.sources);
	push('content_rating', draft.ratings);
	push('category', draft.categories);
	pushNames('author', draft.authors);
	pushNames('tag', draft.tags);
	return rules;
}

export function FilterGroupsSection() {
	const { t } = useTranslation();
	const groups = useFilterGroups();
	const categories = useCategories();
	const sourcesQuery = useSources();
	const authorsQuery = useLibraryAuthors();
	const tagsQuery = useLibraryTags();
	const create = useCreateFilterGroup();
	const update = useUpdateFilterGroup();
	const del = useDeleteFilterGroup();
	const reorder = useReorderFilterGroups();

	const [editing, setEditing] = useState<{ id: number | null; draft: GroupDraft } | null>(null);
	const [deleting, setDeleting] = useState<FilterGroup | null>(null);

	const list = groups.data ?? [];

	function toastError(e: unknown) {
		if (e instanceof ApiError && e.status === 409) pushToast(t('settings.groupExists'));
		else if (e instanceof ApiError) pushToast(translateApiError(e.code, e.message));
		else pushToast(e instanceof Error ? e.message : t('settings.operationFailed'));
	}

	async function submitEditor() {
		if (!editing) return;
		const name = editing.draft.name.trim();
		if (!name) return;
		try {
			if (editing.id === null) {
				await create.mutateAsync({ name, rules: rulesOf(editing.draft) });
				pushToast(t('settings.groupCreated'), 'info');
			} else {
				await update.mutateAsync({ id: editing.id, name, rules: rulesOf(editing.draft) });
				pushToast(t('settings.groupSaved'), 'info');
			}
			setEditing(null);
		} catch (e) {
			toastError(e);
		}
	}

	function move(index: number, delta: number) {
		const ids = list.map((g) => g.id);
		const j = index + delta;
		if (j < 0 || j >= ids.length) return;
		[ids[index], ids[j]] = [ids[j], ids[index]];
		reorder.mutate(ids);
	}

	function cycleTri(dim: 'sources' | 'ratings' | 'categories' | 'authors' | 'tags', key: string) {
		setEditing((cur) => {
			if (!cur) return cur;
			const sel = { ...cur.draft[dim] };
			const next = nextGroupTri(sel[key] ?? 0);
			if (next === 0) delete sel[key];
			else sel[key] = next;
			return { ...cur, draft: { ...cur.draft, [dim]: sel } };
		});
	}

	const saving = create.isPending || update.isPending;

	return (
		<Section title={t('settings.filterGroupsTitle')} desc={t('settings.filterGroupsDesc')}>
			{groups.isPending ? (
				<div className="settings-cats">
					{Array.from({ length: 2 }, (_, i) => (
						<Skeleton key={i} height={56} />
					))}
				</div>
			) : (
				<div className="settings-cats">
					{list.map((g, i) => (
						<div key={g.id} className="settings-cat">
							<div className="settings-cat__head">
								<span className="settings-cat__name">
									{g.name}
									<Badge>{g.rules.length}</Badge>
								</span>
								<span className="settings-cat__ops">
									<IconButton
										label={t('settings.editGroup')}
										size="sm"
										onClick={() => setEditing({ id: g.id, draft: draftOf(g) })}
									>
										<Pencil size={15} />
									</IconButton>
									<IconButton
										label={t('settings.moveUp')}
										size="sm"
										disabled={i === 0 || reorder.isPending}
										onClick={() => move(i, -1)}
									>
										<ArrowUp size={15} />
									</IconButton>
									<IconButton
										label={t('settings.moveDown')}
										size="sm"
										disabled={i === list.length - 1 || reorder.isPending}
										onClick={() => move(i, 1)}
									>
										<ArrowDown size={15} />
									</IconButton>
									<IconButton
										label={t('settings.deleteGroup')}
										size="sm"
										variant="danger"
										onClick={() => setDeleting(g)}
									>
										<Trash2 size={15} />
									</IconButton>
								</span>
							</div>
						</div>
					))}
				</div>
			)}

			<div className="settings-cat__create">
				<Button variant="primary" onClick={() => setEditing({ id: null, draft: EMPTY_DRAFT })}>
					{t('settings.createGroup')}
				</Button>
			</div>

			<Modal
				open={editing !== null}
				title={editing?.id === null ? t('settings.createGroupTitle') : t('settings.editGroupTitle')}
				onClose={() => setEditing(null)}
				panelClassName="modal__panel--wide"
				footer={
					<>
						<Button onClick={() => setEditing(null)}>{t('common.cancel')}</Button>
						<Button
							variant="primary"
							loading={saving}
							disabled={!editing?.draft.name.trim()}
							onClick={() => void submitEditor()}
						>
							{t('common.save')}
						</Button>
					</>
				}
			>
				{editing && (
					<div className="settings-group-editor">
						<Input
							className="settings-modal-input"
							placeholder={t('settings.groupNamePlaceholder')}
							value={editing.draft.name}
							onChange={(e) => setEditing({ ...editing, draft: { ...editing.draft, name: e.currentTarget.value } })}
						/>
						{FLAG_RULE_TYPES.map(({ type, labelKey }) => (
							<div key={type} className="settings-cat__field">
								<span className="settings-cat__label">{t(labelKey)}</span>
								<SegmentedControl
									options={[
										{ value: 0, label: t('settings.ruleNone') },
										{ value: 1, label: t('settings.ruleInclude') },
										{ value: -1, label: t('settings.ruleExclude') }
									]}
									value={editing.draft.flags[type]}
									onChange={(v) =>
										setEditing({
											...editing,
											draft: { ...editing.draft, flags: { ...editing.draft.flags, [type]: v } }
										})
									}
								/>
							</div>
						))}
						<div className="settings-cat__field">
							<span className="settings-cat__label">{t('settings.ruleSources')}</span>
							<TriStateDropdown
								label={t('settings.ruleSources')}
								options={(sourcesQuery.data ?? []).map((s) => ({ key: String(s.id), label: s.name }))}
								states={editing.draft.sources}
								onCycle={(k) => cycleTri('sources', k)}
								onReset={() => setEditing({ ...editing, draft: { ...editing.draft, sources: {} } })}
							/>
						</div>
						<div className="settings-cat__field">
							<span className="settings-cat__label">{t('settings.ruleRatings')}</span>
							<TriStateDropdown
								label={t('settings.ruleRatings')}
								options={MANGA_CONTENT_RATING_LEVELS.map((l) => ({ key: String(l.value), label: l.label }))}
								states={editing.draft.ratings}
								onCycle={(k) => cycleTri('ratings', k)}
								onReset={() => setEditing({ ...editing, draft: { ...editing.draft, ratings: {} } })}
							/>
						</div>
						<div className="settings-cat__field">
							<span className="settings-cat__label">{t('settings.ruleCategories')}</span>
							<TriStateDropdown
								label={t('settings.ruleCategories')}
								options={(categories.data ?? []).map((c) => ({ key: String(c.id), label: c.name }))}
								states={editing.draft.categories}
								onCycle={(k) => cycleTri('categories', k)}
								onReset={() => setEditing({ ...editing, draft: { ...editing.draft, categories: {} } })}
							/>
						</div>
						<div className="settings-cat__field">
							<span className="settings-cat__label">{t('library.author')}</span>
							<TriStateDropdown
								label={t('library.author')}
								options={(authorsQuery.data ?? []).map((a) => ({ key: a.name, label: a.name }))}
								states={editing.draft.authors}
								onCycle={(k) => cycleTri('authors', k)}
								onReset={() => setEditing({ ...editing, draft: { ...editing.draft, authors: {} } })}
							/>
						</div>
						<div className="settings-cat__field">
							<span className="settings-cat__label">{t('library.tag')}</span>
							<TriStateDropdown
								label={t('library.tag')}
								options={(tagsQuery.data ?? []).map((tag) => ({ key: tag.name, label: tag.name }))}
								states={editing.draft.tags}
								onCycle={(k) => cycleTri('tags', k)}
								onReset={() => setEditing({ ...editing, draft: { ...editing.draft, tags: {} } })}
							/>
						</div>
					</div>
				)}
			</Modal>

			<Modal
				open={deleting !== null}
				title={t('settings.deleteGroup')}
				onClose={() => setDeleting(null)}
				footer={
					<>
						<Button onClick={() => setDeleting(null)}>{t('common.cancel')}</Button>
						<Button
							variant="danger"
							loading={del.isPending}
							onClick={() => {
								if (!deleting) return;
								del.mutate(deleting.id, {
									onSuccess: () => {
										setDeleting(null);
										pushToast(t('settings.deleted'), 'info');
									}
								});
							}}
						>
							{t('common.delete')}
						</Button>
					</>
				}
			>
				<p className="settings-modal-text">
					{t('settings.deleteGroupConfirm', { name: deleting?.name })}
				</p>
			</Modal>
		</Section>
	);
}

