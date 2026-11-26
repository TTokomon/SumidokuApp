export const SETTINGS_GROUPS = [
	['general', 'settings.groupGeneral'], ['library', 'settings.libraryTitle'], ['reader', 'settings.groupReader'], ['source-lists', 'settings.sourceListsTitle'],
	['automation', 'settings.categoryAutomation'], ['downloads', 'settings.groupDownloads'],
	['backups', 'settings.groupBackups'], ['accounts', 'settings.categoryAccounts'],
	['trackers', 'settings.groupTrackers'], ['system', 'settings.categoryDiagnostics']
] as const;
export type SettingsGroupKey = (typeof SETTINGS_GROUPS)[number][0];
export const SETTINGS_CATEGORIES: ReadonlyArray<{
	id: string; labelKey: string; fallbackLabel: string; sections: readonly SettingsGroupKey[]; keywords: string;
}> = [
	{ id: 'general', labelKey: 'settings.groupGeneral', fallbackLabel: 'General', sections: ['general'], keywords: 'theme appearance language version application updates' },
	{ id: 'reader', labelKey: 'settings.groupReader', fallbackLabel: 'Reader', sections: ['reader'], keywords: 'reading direction layout scaling tap animation background incognito' },
	{ id: 'library', labelKey: 'common.nav.library', fallbackLabel: 'Library', sections: ['library', 'automation'], keywords: 'categories filters organize view options display unread chapter schedule metadata refresh exclusions skip' },
	{ id: 'sources', labelKey: 'settings.sourcesTitle', fallbackLabel: 'Sources', sections: ['source-lists'], keywords: 'sources lists repositories subscriptions packages source updates' },
	{ id: 'storage', labelKey: 'settings.categoryStorage', fallbackLabel: 'Storage & Backups', sections: ['downloads', 'backups'], keywords: 'download format concurrency ahead automatic cleanup folder movement backup import restore schedule' },
	{ id: 'accounts', labelKey: 'settings.categoryAccounts', fallbackLabel: 'Accounts & Integrations', sections: ['accounts', 'trackers'], keywords: 'account password security API keys tracker provider login reconnect disconnect default bindings' },
	{ id: 'server', labelKey: 'settings.categoryDiagnostics', fallbackLabel: 'Server & Diagnostics', sections: ['system'], keywords: 'server cache cleanup runtime logs about diagnostics advanced troubleshooting' }
];
export function settingsCategoryFor(section: SettingsGroupKey) {
	return SETTINGS_CATEGORIES.find((category) => category.sections.includes(section)) ?? SETTINGS_CATEGORIES[0]!;
}
export function contextualSettingsRoute(section: string | null): string | null {
	void section;
	return null;
}
