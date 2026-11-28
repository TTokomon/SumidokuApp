import { useTranslation } from 'react-i18next';
import type { AidokuImportResponse } from '../../api/types';
import type { AidokuImportStep } from './AidokuImportSession';
import { missingAidokuIds } from './AidokuSourceRecovery';

const sections = ['library', 'progress', 'categories', 'trackers'] as const;

export function AidokuWizardSteps({ step }: { step: AidokuImportStep }) {
	const { t } = useTranslation();
	return <ol className="aidoku-wizard__steps" aria-label={t('aidokuWizard.steps')}>
		{(['reviewBackup', 'restoreSources', 'finish'] as const).map((key, index) => <li key={key} aria-current={index + 1 === step ? 'step' : undefined} data-complete={index + 1 < step}>
			<span>{index + 1}</span>{t('aidokuWizard.' + key)}
		</li>)}
	</ol>;
}

export function AidokuWizardSummary({ result }: { result: AidokuImportResponse }) {
	const { t, i18n } = useTranslation();
	const format = new Intl.NumberFormat(i18n.resolvedLanguage || 'en');
	const missing = missingAidokuIds(result).length;
	const kept = result.keptProgress ?? 0;
	const corrected = result.correctedProgress ?? 0;
	return <section className="aidoku-wizard__summary">
		<h3>{t(result.dryRun ? 'aidokuWizard.ready' : 'aidokuWizard.complete')}</h3>
		<p>{t(result.dryRun ? 'aidokuWizard.previewHelp' : 'settings.aidokuReport.completedHelp')}</p>
		<dl className="aidoku-wizard__counts">{sections.map(section => <div key={section}>
			<dt>{t('settings.aidokuReport.sections.' + section)}</dt>
			<dd>{format.format(result.imported[section])}</dd>
		</div>)}</dl>
		{missing > 0 && <p className="aidoku-wizard__notice">{t('aidokuWizard.missing', { count: missing })} {t('aidokuWizard.offlineHelp')}</p>}
		{(result.archivedTrackers ?? 0) > 0 && <p className="aidoku-wizard__notice">{t('aidokuWizard.inactiveTrackers', { defaultValue: 'Inactive tracker bindings preserved' })}: {format.format(result.archivedTrackers ?? 0)}. {t('aidokuWizard.inactiveTrackerHelp', { defaultValue: 'These trackers are not supported yet. Their associations are saved but will not sync.' })}</p>}
		{!result.dryRun && kept > 0 && <p>{t('aidokuWizard.progressKept', { defaultValue: 'Kept Sumidoku progress' })}: {format.format(kept)}</p>}
		{!result.dryRun && corrected > 0 && <p>{t('aidokuWizard.progressCorrected', { defaultValue: 'Applied selected Aidoku corrections' })}: {format.format(corrected)}</p>}
		{result.skipped.length > 0 && <p className="settings-backup__warn">{t(result.dryRun ? 'settings.aidokuReport.willSkip' : 'settings.aidokuReport.skipped', { count: result.skipped.length })}</p>}
	</section>;
}

export function AidokuProgressReview({ result, selected, onChange, disabled }: {
	result: AidokuImportResponse; selected: number[]; onChange: (selected: number[]) => void; disabled: boolean;
}) {
	const { t, i18n } = useTranslation();
	const differences = result.progressDifferences ?? [];
	if (!differences.length) return null;
	const number = new Intl.NumberFormat(i18n.resolvedLanguage || 'en');
	function progress(page: number | null, read: boolean | null) {
		const position = page === null ? t('aidokuWizard.pageUnknown', { defaultValue: 'Page unknown' })
			: t('aidokuWizard.pagePosition', { defaultValue: 'Page position {{page}}', page: number.format(page) });
		const status = read === null ? t('aidokuWizard.readUnknown', { defaultValue: 'Read status unknown' })
			: read ? t('aidokuWizard.progressRead', { defaultValue: 'Read' }) : t('aidokuWizard.progressUnread', { defaultValue: 'Unread' });
		return `${position} · ${status}`;
	}
	return <details className="settings-backup__skipped">
		<summary>{t('aidokuWizard.progressDifferences', { defaultValue: 'Reading progress differences' })} ({number.format(differences.length)})</summary>
		<p>{t('aidokuWizard.progressReviewHelp', { defaultValue: 'Sumidoku keeps its current progress unless you select a chapter below. A selected Aidoku value can rewind progress or mark a chapter unread.' })}</p>
		<ul>
			{differences.map((difference) => {
				const checked = selected.includes(difference.chapterId);
				return <li key={difference.chapterId}>
					<strong>{difference.mangaTitle} · {difference.chapterTitle}</strong>
					<div>Sumidoku — {progress(difference.currentPage, difference.currentRead)}</div>
					<div>Aidoku — {progress(difference.backupPage, difference.backupRead)}</div>
					{difference.protected && <div>{t('aidokuWizard.protectedProgress', { defaultValue: 'Previous correction protected' })}</div>}
					{difference.canCorrect ? <label className="aidoku-wizard__ack">
						<input type="checkbox" checked={checked} disabled={disabled || (!checked && selected.length >= 100)}
							aria-label={t('aidokuWizard.useAidokuProgressFor', { defaultValue: 'Use Aidoku progress for {{manga}}, {{chapter}}', manga: difference.mangaTitle, chapter: difference.chapterTitle })}
							onChange={() => onChange(checked ? selected.filter(id => id !== difference.chapterId) : [...selected, difference.chapterId])} />
						{t('aidokuWizard.useAidokuProgress', { defaultValue: 'Use Aidoku progress for this chapter' })}
					</label> : <div>{t('aidokuWizard.progressCannotCorrect', { defaultValue: 'Kept in Sumidoku. The chapter or backup progress cannot be used for a correction.' })}</div>}
				</li>;
			})}
		</ul>
	</details>;
}
