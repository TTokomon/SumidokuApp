import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { AidokuImportResponse, AidokuIncluded, AidokuSkipped } from '../../api/types';
import { Button } from '../../components';
import { aidokuSourceLabel } from './aidokuRecovery';

const PAGE_SIZE = 25;
const sections = ['library', 'categories', 'progress', 'trackers'] as const;

function ReportList({ label, items, expanded = false }: { label: string; items: string[]; expanded?: boolean }) {
	const { t } = useTranslation();
	const [visible, setVisible] = useState(PAGE_SIZE);
	const [open, setOpen] = useState(expanded);
	if (!items.length) return null;
	return (
		<details className="settings-backup__skipped" open={open} onToggle={(event) => setOpen(event.currentTarget.open)}>
			<summary>{label} ({items.length})</summary>
			{open && <>
				<ul className="settings-backup__warnings">
					{items.slice(0, visible).map((item, index) => <li key={index}>{item}</li>)}
				</ul>
				{visible < items.length && (
					<Button onClick={() => setVisible(visible + PAGE_SIZE)}>
						{t('settings.aidokuReport.showMore', { count: Math.min(PAGE_SIZE, items.length - visible) })}
					</Button>
				)}
			</>}
		</details>
	);
}

function entryLabel(entry: AidokuIncluded) {
	const manga = entry.mangaTitle
		? `${entry.mangaTitle} (${entry.sourceKey}/${entry.mangaKey})`
		: `${entry.sourceKey}/${entry.mangaKey}`;
	const chapter = entry.chapterTitle && entry.chapterKey
		? `${entry.chapterTitle} (${entry.chapterKey})`
		: entry.chapterTitle || entry.chapterKey;
	return [manga, chapter, entry.trackerId].filter(Boolean).join(' · ');
}

export function AidokuImportReport({ result }: { result: AidokuImportResponse }) {
	const { t } = useTranslation();
	const sectionLabel = (section: string) => sections.some((value) => value === section)
		? t(`settings.aidokuReport.sections.${section}`)
		: section;
	const skippedBySection = new Map<string, AidokuSkipped[]>();
	for (const entry of result.skipped) {
		const key = entry.reason === 'source not installed' ? `source:${entry.sourceKey}` : entry.section;
		const group = skippedBySection.get(key);
		if (group) group.push(entry);
		else skippedBySection.set(key, [entry]);
	}
	const categoryNames = result.categoryNames ?? [];
	const hasEligible = sections.some((section) => result.imported[section] > 0);
	return (
		<div className="settings-backup__result">
			<h3>{t(result.dryRun ? 'settings.aidokuReport.preview' : 'settings.aidokuReport.completed')}</h3>
			<p className="settings-modal-text">{t(result.dryRun ? 'settings.aidokuReport.previewHelp' : 'settings.aidokuReport.completedHelp')}</p>
			<h4>{t(result.dryRun ? 'settings.aidokuReport.willMerge' : 'settings.aidokuReport.merged')}</h4>
			{hasEligible ? (
				<ul className="settings-backup__warnings">
					{sections.map((section) => <li key={section}>{sectionLabel(section)}: {result.imported[section]}</li>)}
				</ul>
			) : <p>{t('settings.aidokuReport.noEligible')}</p>}
			{sections.map((section) => (
				<ReportList
					key={section}
					label={sectionLabel(section)}
					expanded={false}
					items={section === 'categories' ? categoryNames : (result.included ?? []).filter((entry) => entry.section === section).map(entryLabel)}
				/>
			))}
			{(result.archivedTrackers ?? 0) > 0 && <ReportList label={t('aidokuWizard.inactiveTrackers', { defaultValue: 'Inactive tracker bindings preserved' })} items={(result.included ?? []).filter(entry => entry.section === 'archivedTrackers').map(entryLabel)} />}
			{(result.missingSources ?? []).length > 0 && <p className="settings-modal-text">{t('settings.aidokuReport.savedWithoutSources', { defaultValue: 'Library records from unavailable sources are preserved. Install the matching extensions to read those titles again.' })}</p>}
			<h4>{t(result.dryRun ? 'settings.aidokuReport.willSkip' : 'settings.aidokuReport.skipped', { count: result.skipped.length })}</h4>
			{result.skipped.length === 0 && <p>{t('settings.aidokuReport.noSkips')}</p>}
			{[...skippedBySection].map(([section, entries]) => (
				<ReportList key={section} label={section.startsWith('source:') ? aidokuSourceLabel(section.slice(7)) : sectionLabel(section)} items={entries.map((entry) => {
					const reason = t(`settings.aidokuReport.reasons.${entry.reason}`, { defaultValue: entry.reason });
					return `${entryLabel(entry)} — ${reason}`;
				})} />
			))}
			<h4>{t('settings.aidokuReport.unsupported')}</h4>
			<p className="settings-modal-text">{t('settings.aidokuReport.unsupportedHelp')}</p>
		</div>
	);
}
