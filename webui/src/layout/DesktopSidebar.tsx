import type { ReactNode } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { PanelLeftClose, PanelLeftOpen } from 'lucide-react';
import { IconButton } from '../components';
import { NAV } from './navigation';

interface DesktopSidebarProps {
	collapsed: boolean;
	onToggle: () => void;
	children: ReactNode;
}

const COLLECTION_NAV = NAV.filter((item) => item.to !== '/settings');
const SETTINGS_NAV = NAV.find((item) => item.to === '/settings')!;

function SidebarLink({ item, collapsed }: {
	item: (typeof NAV)[number];
	collapsed: boolean;
}) {
	const { t } = useTranslation();
	const { pathname } = useLocation();
	const active = item.to === '/settings'
		? pathname.startsWith('/settings')
		: pathname === item.to || (item.to === '/library' && pathname.startsWith('/manga/')) ||
			(item.to === '/browse' && pathname.startsWith('/browse/'));
	const Icon = item.icon;
	return (
		<NavLink
			to={item.to}
			viewTransition
			className={active ? 'side-nav__item side-nav__item--active' : 'side-nav__item'}
			aria-current={active ? 'page' : undefined}
			aria-label={collapsed ? t(item.labelKey) : undefined}
			title={collapsed ? t(item.labelKey) : undefined}
		>
			<Icon size={22} strokeWidth={2.2} aria-hidden="true" />
			<span className="side-nav__label" hidden={collapsed}>{t(item.labelKey)}</span>
		</NavLink>
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
				<SidebarLink item={SETTINGS_NAV} collapsed={collapsed} />
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
