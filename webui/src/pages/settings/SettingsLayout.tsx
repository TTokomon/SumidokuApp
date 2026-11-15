import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';

export const SETTINGS_GROUPS = [
	['general', 'settings.groupGeneral'],
	['reader', 'settings.groupReader'],
	['library', 'settings.groupLibrary'],
	['trackers', 'settings.groupTrackers'],
	['downloads', 'settings.groupDownloads'],
	['backups', 'settings.groupBackups'],
	['source-lists', 'settings.groupSourceLists'],
	['system', 'settings.groupSystem']
] as const;

export type SettingsGroupKey = (typeof SETTINGS_GROUPS)[number][0];

const SUBSECTION_LABELS: Record<SettingsGroupKey, string> =
	Object.fromEntries(SETTINGS_GROUPS) as Record<SettingsGroupKey, string>;

/** Five visible categories; keep all eight legacy deep-link section IDs intact. */
export const SETTINGS_CATEGORIES: ReadonlyArray<{
	id: string;
	labelKey: string;
	fallbackLabel: string;
	sections: readonly SettingsGroupKey[];
}> = [
	{ id: 'reading', labelKey: 'settings.categoryReadingLibrary', fallbackLabel: 'Reading & Library', sections: ['reader', 'library'] },
	{ id: 'sources', labelKey: 'settings.categorySourcesTracking', fallbackLabel: 'Sources & Tracking', sections: ['source-lists', 'trackers'] },
	{ id: 'storage', labelKey: 'settings.categoryDownloadsBackups', fallbackLabel: 'Downloads & Backups', sections: ['downloads', 'backups'] },
	{ id: 'appearance', labelKey: 'settings.categoryAppearanceUpdates', fallbackLabel: 'Appearance & Updates', sections: ['general'] },
	{ id: 'server', labelKey: 'settings.categoryServerAccount', fallbackLabel: 'Server & Account', sections: ['system'] }
];

/** The old section query parameter continues to determine both category and subsection. */
export function settingsCategoryFor(section: SettingsGroupKey) {
	return SETTINGS_CATEGORIES.find((category) => category.sections.includes(section)) ?? SETTINGS_CATEGORIES[3]!;
}

interface SettingsLayoutProps {
	current: SettingsGroupKey;
	onSelect: (key: SettingsGroupKey) => void;
	panels: Record<SettingsGroupKey, ReactNode>;
}

export function SettingsLayout({ current, onSelect, panels }: SettingsLayoutProps) {
	const { t } = useTranslation();
	const active = SETTINGS_GROUPS.some(([key]) => key === current) ? current : 'general';
	const category = settingsCategoryFor(active);
	return (
		<div className="settings-layout">
			<nav className="settings-nav" aria-label="Settings categories">
				{SETTINGS_CATEGORIES.map((item) => (
					<button
						type="button"
						key={item.id}
						data-settings-category={item.id}
						className={category.id === item.id ? 'settings-nav__item settings-nav__item--active' : 'settings-nav__item'}
						aria-pressed={category.id === item.id}
						onClick={() => onSelect(item.sections[0]!)}
					>{t(item.labelKey, { defaultValue: item.fallbackLabel })}</button>
				))}
			</nav>
			<div className="settings-panel">
				{category.sections.length > 1 && (
					<nav className="settings-subnav" aria-label={t('settings.groupNav')}>
						{category.sections.map((section) => (
							<button
								type="button"
								key={section}
								data-settings-group={section}
								className={active === section ? 'settings-subnav__item settings-subnav__item--active' : 'settings-subnav__item'}
								aria-current={active === section ? 'page' : undefined}
								onClick={() => onSelect(section)}
							>{t(SUBSECTION_LABELS[section])}</button>
						))}
					</nav>
				)}
				{SETTINGS_GROUPS.map(([key]) => (
					<div key={key} data-settings-panel={key} hidden={active !== key}>
						{panels[key]}
					</div>
				))}
			</div>
		</div>
	);
}
