import { useState } from 'react';
import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { Button, Input } from '../../components';
import { SETTINGS_CATEGORIES, SETTINGS_GROUPS, settingsCategoryFor } from './navigation';
import type { SettingsGroupKey } from './navigation';
export { SETTINGS_CATEGORIES, SETTINGS_GROUPS, settingsCategoryFor } from './navigation';
export type { SettingsGroupKey } from './navigation';

interface SettingsLayoutProps {
	current: SettingsGroupKey;
	onSelect: (key: SettingsGroupKey | 'library' | 'source-lists') => void;
	panels: Record<SettingsGroupKey, ReactNode>;
}
export function SettingsLayout({ current, onSelect, panels }: SettingsLayoutProps) {
	const { t } = useTranslation();
	const [search, setSearch] = useState('');
	const active = SETTINGS_GROUPS.some(([key]) => key === current) ? current : 'general';
	const category = settingsCategoryFor(active);
	const query = search.trim().toLocaleLowerCase();
	return <div className="settings-layout">
		<Input type="search" aria-label="Search settings" placeholder="Search settings and contextual tools" value={search} onChange={(event) => setSearch(event.currentTarget.value)} />
		{query && <nav className="settings-search-results" aria-label="Settings search results">
			{SETTINGS_CATEGORIES.filter((item) => `${t(item.labelKey, { defaultValue: item.fallbackLabel })} ${item.keywords}`.toLocaleLowerCase().includes(query)).map((item) => <Button key={item.id} onClick={() => { onSelect(item.sections[0]!); setSearch(''); }}>{t(item.labelKey, { defaultValue: item.fallbackLabel })}</Button>)}
			{'library categories filters organize view options'.includes(query) && <Button onClick={() => onSelect('library')}>Library → Organize & View Options</Button>}
			{'sources lists repositories subscriptions packages'.includes(query) && <Button onClick={() => onSelect('source-lists')}>Sources → Source Lists</Button>}
		</nav>}
		<nav className="settings-nav" aria-label="Settings categories">
			{SETTINGS_CATEGORIES.map((item) => <button type="button" key={item.id} data-settings-category={item.id} className={category.id === item.id ? 'settings-nav__item settings-nav__item--active' : 'settings-nav__item'} aria-pressed={category.id === item.id} onClick={() => onSelect(item.sections[0]!)}>{t(item.labelKey, { defaultValue: item.fallbackLabel })}</button>)}
		</nav>
		<div className="settings-panel">
			{category.sections.length > 1 && <nav className="settings-subnav" aria-label={t('settings.groupNav')}>
				{category.sections.map((section) => <button type="button" key={section} data-settings-group={section} className={active === section ? 'settings-subnav__item settings-subnav__item--active' : 'settings-subnav__item'} aria-current={active === section ? 'page' : undefined} onClick={() => onSelect(section)}>{t(Object.fromEntries(SETTINGS_GROUPS)[section])}</button>)}
			</nav>}
			{SETTINGS_GROUPS.map(([key]) => <div key={key} data-settings-panel={key} hidden={active !== key}>{panels[key]}</div>)}
		</div>
	</div>;
}
