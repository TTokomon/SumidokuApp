import type { ReactNode } from 'react';
import { Link, NavLink, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { BookOpen, CalendarClock, HardDrive, Users, PanelLeftClose, PanelLeftOpen, Server, Settings as SettingsIcon } from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import { IconButton } from '../components';
import { SETTINGS_CATEGORIES, contextualSettingsRoute } from '../pages/settings/navigation';
import { NAV } from './navigation';

interface DesktopSidebarProps {
	collapsed: boolean;
	onToggle: () => void;
	children: ReactNode;
}

interface SidebarItem {
	to: string;
	labelKey: string;
	icon: LucideIcon;
	fallbackLabel?: string;
	sections?: readonly string[];
	tone: string;
}

const COLLECTION_NAV: SidebarItem[] = NAV.filter((item) => item.to !== '/settings')
	.map((item) => ({ ...item, tone: item.to.slice(1) }));

const PREFERENCE_ICONS: Record<string, LucideIcon> = {
	general: SettingsIcon,
	reader: BookOpen,
	automation: CalendarClock,
	storage: HardDrive,
	accounts: Users,
	server: Server
};
const PREFERENCES_NAV: SidebarItem[] = SETTINGS_CATEGORIES.map((category) => ({
	to: `/settings?section=${category.sections[0]}`,
	labelKey: category.labelKey,
	fallbackLabel: category.fallbackLabel,
	icon: PREFERENCE_ICONS[category.id] ?? SettingsIcon,
	sections: category.sections,
	tone: category.id
}));

function SidebarLink({ item, collapsed }: { item: SidebarItem; collapsed: boolean }) {
	const { t } = useTranslation();
	const { pathname, search } = useLocation();
	const section = new URLSearchParams(search).get('section') ?? 'general';
	const effectivePath = pathname === '/settings' ? contextualSettingsRoute(section)?.split('?')[0] ?? pathname : pathname;
	const active = item.sections
		? pathname === '/settings' && item.sections.includes(section)
		: effectivePath === item.to || (item.to === '/library' && pathname.startsWith('/manga/')) ||
			(item.to === '/browse' && pathname.startsWith('/browse/'));
	const Icon = item.icon;
	const label = t(item.labelKey, { defaultValue: item.fallbackLabel ?? item.labelKey });
	return (
		<Link
			to={item.to}
			viewTransition
			className={active ? 'side-nav__item side-nav__item--active' : 'side-nav__item'}
			data-sidebar-tone={item.tone}
			aria-current={active ? 'page' : undefined}
			aria-label={collapsed ? label : undefined}
			title={collapsed ? label : undefined}
		>
			<Icon size={18} strokeWidth={2} aria-hidden="true" />
			<span className="side-nav__label" hidden={collapsed}>{label}</span>
		</Link>
	);
}

export function DesktopSidebar({ collapsed, onToggle, children }: DesktopSidebarProps) {
	const { t } = useTranslation();
	return (
		<aside id="desktop-sidebar" className={collapsed ? 'app__sidebar app__sidebar--collapsed' : 'app__sidebar'}>
			<NavLink to="/library" className="app__logo" aria-label={collapsed ? 'Sumidoku' : undefined} title={collapsed ? 'Sumidoku' : undefined}>
				<img className="app__logo-mark" src="/icon.svg" alt="" />
				<span className="app__logo-text" hidden={collapsed}>Sumidoku</span>
			</NavLink>
			<nav className="side-nav" aria-label={t('layout.primaryNav')}>
				<span className="side-nav__heading" hidden={collapsed}>Collection</span>
				{COLLECTION_NAV.map((item) => <SidebarLink key={item.to} item={item} collapsed={collapsed} />)}
				<span className="side-nav__heading side-nav__heading--separated" hidden={collapsed}>Preferences</span>
				{PREFERENCES_NAV.map((item) => <SidebarLink key={item.to} item={item} collapsed={collapsed} />)}
			</nav>
			<div className="app__sidebar-foot">
				<IconButton
					className="app__sidebar-toggle"
					label={collapsed ? t('layout.expandSidebar') : t('layout.collapseSidebar')}
					onClick={onToggle}
					aria-expanded={!collapsed}
					aria-controls="desktop-sidebar"
				>
					{collapsed ? <PanelLeftOpen size={17} /> : <PanelLeftClose size={17} />}
				</IconButton>
				{children}
			</div>
		</aside>
	);
}
