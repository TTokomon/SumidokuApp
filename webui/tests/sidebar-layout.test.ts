import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { createServer } from 'vite';
import { readSidebarCollapsed, writeSidebarCollapsed } from '../src/lib/sidebarPrefs.ts';

async function renderSidebar(collapsed: boolean, path = '/'): Promise<string> {
	const vite = await createServer({
		root: fileURLToPath(new URL('../', import.meta.url)),
		configFile: false,
		logLevel: 'silent',
		appType: 'custom',
		server: { middlewareMode: true }
	});
	try {
		// the assertions match English labels: force the language instead of inheriting the machine locale
		const { default: i18n } = await vite.ssrLoadModule('/src/i18n');
		await i18n.changeLanguage('en');
		const { DesktopSidebar } = await vite.ssrLoadModule('/src/layout/DesktopSidebar.tsx');
		return renderToStaticMarkup(
			createElement(
				MemoryRouter,
				{ initialEntries: [path] },
				createElement(DesktopSidebar, { collapsed, onToggle: () => {} }, createElement('span', null, 'Theme'))
			)
		);
	} finally {
		await vite.close();
	}
}

test('collapsed sidebar keeps accessible icon navigation', async () => {
	const markup = await renderSidebar(true);
	assert.match(markup, /class="app__sidebar app__sidebar--collapsed"/);
	assert.match(markup, /class="app__logo-text" hidden="">Sumidoku/);
	assert.match(markup, /class="side-nav__label" hidden="">Library/);
	assert.match(markup, /aria-label="Library"/);
	assert.match(markup, /aria-label="Primary navigation"/);
	assert.match(markup, /aria-label="Expand sidebar"/);
	assert.match(markup, /aria-expanded="false"/);
	assert.match(markup, /aria-controls="desktop-sidebar"/);
});

test('expanded sidebar keeps visible labels and collapse control', async () => {
	const markup = await renderSidebar(false);
	assert.doesNotMatch(markup, /app__sidebar--collapsed/);
	assert.match(markup, /class="app__logo-text">Sumidoku/);
	assert.match(markup, /class="side-nav__label">Library/);
	assert.match(markup, /aria-label="Collapse sidebar"/);
	assert.match(markup, /aria-expanded="true"/);
});

test('sidebar shows five Collection items and six Preferences shortcuts', async () => {
	const markup = await renderSidebar(false);
	const navigation = markup.slice(markup.indexOf('<nav'), markup.indexOf('</nav>'));
	assert.deepEqual(
		[...navigation.matchAll(/href="([^"]+)"/g)].map((match) => match[1]),
		[
			'/library', '/browse', '/history', '/downloads', '/updates',
			'/settings?section=general',
			'/settings?section=reader',
			'/settings?section=automation',
			'/settings?section=downloads',
			'/settings?section=accounts',
			'/settings?section=system'
		]
	);
	for (const heading of ['Collection', 'Preferences', 'General', 'Reader', 'Automation', 'Storage &amp; Backups', 'Accounts &amp; Integrations', 'Server &amp; Diagnostics']) {
		assert.ok(navigation.includes(heading), heading);
	}
	assert.doesNotMatch(navigation, /data-nav-group/);
});

test('legacy Settings section links select the correct consolidated Preferences shortcut', async () => {
	const sections: Record<string, string> = {
		downloads: 'downloads', backups: 'downloads',
		trackers: 'accounts', accounts: 'accounts', automation: 'automation',
		reader: 'reader',
		system: 'system', general: 'general'
	};
	for (const [section, destination] of Object.entries(sections)) {
		const markup = await renderSidebar(false, `/settings?section=${section}`);
		const activeHrefs = [...markup.matchAll(/<a\b[^>]*>/g)]
			.filter(([anchor]) => anchor.includes('side-nav__item--active'))
			.map(([anchor]) => anchor.match(/href="([^"]+)"/)?.[1]);
		assert.deepEqual(activeHrefs, [`/settings?section=${destination}`], section);
	}
});

test('sidebar preference round-trips and rejects unknown values', () => {
	const values = new Map<string, string>();
	const original = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
	Object.defineProperty(globalThis, 'localStorage', {
		configurable: true,
		value: {
			getItem: (key: string) => values.get(key) ?? null,
			setItem: (key: string, value: string) => values.set(key, String(value))
		}
	});
	try {
		assert.equal(readSidebarCollapsed(), false);
		writeSidebarCollapsed(true);
		assert.equal(values.get('sumidoku.sidebar.collapsed'), 'true');
		assert.equal(readSidebarCollapsed(), true);
		writeSidebarCollapsed(false);
		assert.equal(readSidebarCollapsed(), false);
		values.set('sumidoku.sidebar.collapsed', 'unexpected');
		assert.equal(readSidebarCollapsed(), false);
	} finally {
		if (original) Object.defineProperty(globalThis, 'localStorage', original);
		else Reflect.deleteProperty(globalThis, 'localStorage');
	}
});

test('collapsing keeps the sidebar toggle at the same spot', async () => {
	const css = readFileSync(new URL('../src/layout/layout.css', import.meta.url), 'utf8');
	const rule = (selector: string) =>
		css.match(new RegExp(`${selector.replace(/[.]/g, '\\.')}\\s*\\{([^}]*)\\}`))?.[1] ?? '';
	// The toggle renders first, so a reversed column stacks the shell actions above it
	// and leaves it on the bottom row it occupies when expanded.
	const markup = await renderSidebar(true);
	const foot = markup.slice(markup.indexOf('app__sidebar-foot'));
	assert.ok(foot.indexOf('app__sidebar-toggle') >= 0);
	assert.ok(foot.indexOf('app__sidebar-toggle') < foot.indexOf('<span>Theme</span>'));
	assert.match(rule('.app__sidebar--collapsed .app__sidebar-foot'), /flex-direction:\s*column-reverse;/);
	// Collapsed, the 34px toggle centers in the 72px rail's 47px content box at 6.5px;
	// the expanded footer starts it at the same 6.5px so it does not shift sideways.
	assert.match(rule('.app__sidebar-foot'), /padding:\s*8px 4px 0 6\.5px;/);
});


test('Source Lists stays visible inside the grouped Settings page without losing hidden panels', async () => {
	const vite = await createServer({
		root: fileURLToPath(new URL('../', import.meta.url)),
		configFile: false, logLevel: 'silent', appType: 'custom', server: { middlewareMode: true }
	});
	try {
		const { SettingsLayout, SETTINGS_GROUPS } = await vite.ssrLoadModule('/src/pages/settings/SettingsLayout.tsx');
		const panels = Object.fromEntries(SETTINGS_GROUPS.map(([id]: [string]) => [id, createElement('span', null, id)]));
		const markup = renderToStaticMarkup(createElement(SettingsLayout, {
			current: 'trackers', onSelect: () => {}, panels
		}));
		assert.equal((markup.match(/data-settings-category=/g) ?? []).length, 6);
		assert.match(markup, /data-settings-group="trackers"[^>]*aria-current="page"/);
		assert.match(markup, /data-settings-group="accounts"/);
		assert.equal((markup.match(/data-settings-panel=/g) ?? []).length, 8);
		assert.match(markup, /data-settings-panel="trackers">/);
	} finally { await vite.close(); }
});

test('six Settings categories preserve every historical deep link', async () => {
	const vite = await createServer({
		root: fileURLToPath(new URL('../', import.meta.url)),
		configFile: false, logLevel: 'silent', appType: 'custom', server: { middlewareMode: true }
	});
	try {
		const { SETTINGS_GROUPS, SETTINGS_CATEGORIES, settingsCategoryFor } =
			await vite.ssrLoadModule('/src/pages/settings/SettingsLayout.tsx');
		assert.equal(SETTINGS_CATEGORIES.length, 6);
		const all = SETTINGS_CATEGORIES.flatMap((group: { sections: string[] }) => group.sections);
		assert.deepEqual(new Set(all), new Set(SETTINGS_GROUPS.map(([id]: [string]) => id)));
				assert.equal(settingsCategoryFor('trackers').id, 'accounts');
		assert.equal(settingsCategoryFor('system').id, 'server');
		assert.equal(settingsCategoryFor('general').id, 'general');
		assert.equal(settingsCategoryFor('reader').id, 'reader');
		assert.equal(settingsCategoryFor('automation').id, 'automation');
	} finally { await vite.close(); }
});

test('query-based Preferences expose exactly one current destination', async () => {
	for (const [route, expected] of [
		['/settings?section=general', 'general'],
		['/settings?section=reader', 'reader'],
		['/settings?section=trackers', 'accounts'],
		['/settings?section=backups', 'downloads']
	]) {
		const markup = await renderSidebar(false, route);
		const navigation = markup.slice(markup.indexOf('<nav'), markup.indexOf('</nav>'));
		const current = [...navigation.matchAll(/<a\b[^>]*>/g)]
			.filter(([anchor]) => anchor.includes('aria-current="page"'))
			.map(([anchor]) => anchor.match(/href="([^"]+)"/)?.[1]);
		assert.deepEqual(current, [`/settings?section=${expected}`], route);
	}
});

 test('all browser destination icons are distinct', async () => {
    const markup = await renderSidebar(false);
    const navigation = markup.slice(markup.indexOf('<nav'), markup.indexOf('</nav>'));
    const icons = [...navigation.matchAll(/class="lucide ([^"]+)"/g)].map((match) => match[1]);
    assert.equal(icons.length, 11);
    assert.equal(new Set(icons).size, 11);
});
