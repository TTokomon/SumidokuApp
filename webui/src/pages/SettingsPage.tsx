import { Navigate, useSearchParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { PageHeader } from '../components';
import { DesktopUpdatesSection, DesktopServerSection } from '../native/DesktopBridge';
import { SettingsLayout, SETTINGS_GROUPS, settingsCategoryFor } from './settings/SettingsLayout';
import { contextualSettingsRoute } from './settings/navigation';
import { TrackersPanel } from './settings/TrackersPanel';
import { SourceAutomation } from './settings/SourceLists';
import {
	AppearanceSection, ReaderSection, IncognitoSection, LibraryUpdateSection,
	DownloadSection, DownloadMoveSection, BackupSection, ScheduledBackupSection,
	SecuritySection, ApiKeysSection, CoverCacheSection, ChapterCacheSection, AboutSection
} from './settings/SettingsSections';
import './settings.css';

export default function SettingsPage() {
	const { t } = useTranslation();
	const [params, setParams] = useSearchParams();
	const requested = params.get('section');
	const contextual = contextualSettingsRoute(requested);
	const current = SETTINGS_GROUPS.find(([key]) => key === requested)?.[0] ?? 'general';
	const category = settingsCategoryFor(current);
	if (contextual) return <Navigate to={contextual} replace />;
	return <div className="page container settings-page">
		<PageHeader title={t(category.labelKey, { defaultValue: category.fallbackLabel })} />
		<SettingsLayout current={current} onSelect={(section) => setParams({ section })} panels={{
			general: <><AppearanceSection /><DesktopUpdatesSection /></>,
			reader: <><ReaderSection /><IncognitoSection /></>,
			automation: <><LibraryUpdateSection /><SourceAutomation /></>,
			downloads: <><DownloadSection /><DownloadMoveSection /></>,
			backups: <><BackupSection /><ScheduledBackupSection /></>,
			accounts: <><SecuritySection /><ApiKeysSection /></>,
			trackers: <TrackersPanel />,
			system: <><DesktopServerSection /><CoverCacheSection /><ChapterCacheSection /><AboutSection /></>
		}} />
	</div>;
}
