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
	return <section className="aidoku-wizard__summary">
		<h3>{t(result.dryRun ? 'aidokuWizard.ready' : 'aidokuWizard.complete')}</h3>
		<p>{t(result.dryRun ? 'aidokuWizard.previewHelp' : 'settings.aidokuReport.completedHelp')}</p>
		<dl className="aidoku-wizard__counts">{sections.map(section => <div key={section}>
			<dt>{t('settings.aidokuReport.sections.' + section)}</dt>
			<dd>{format.format(result.imported[section])}</dd>
		</div>)}</dl>
		{missing > 0 && <p className="aidoku-wizard__notice">{t('aidokuWizard.missing', { count: missing })} {t('aidokuWizard.offlineHelp')}</p>}
		{result.skipped.length > 0 && <p className="settings-backup__warn">{t(result.dryRun ? 'settings.aidokuReport.willSkip' : 'settings.aidokuReport.skipped', { count: result.skipped.length })}</p>}
	</section>;
}
