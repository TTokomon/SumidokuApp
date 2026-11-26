import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';

async function renderSettings(section: string): Promise<string> {
	const vite = await createServer({
		root: fileURLToPath(new URL('../', import.meta.url)),
		configFile: false,
		logLevel: 'silent',
		appType: 'custom',
		server: { middlewareMode: true }
	});
	try {
		await vite.ssrLoadModule('/src/i18n');
		const { SettingsLayout, SETTINGS_GROUPS } = await vite.ssrLoadModule('/src/pages/settings/SettingsLayout.tsx');
		const panels = Object.fromEntries(SETTINGS_GROUPS.map(([key]: [string, string]) => [key, key]));
		return renderToStaticMarkup(createElement(SettingsLayout, { current: section, onSelect: () => {}, panels }));
	} finally {
		await vite.close();
	}
}

test('settings deep link selects the requested group and hides only the other panels', async () => {
	const markup = await renderSettings('downloads');
	for (const group of ['general', 'library', 'reader', 'source-lists', 'automation', 'trackers', 'downloads', 'backups', 'accounts', 'system']) {
		assert.match(markup, new RegExp(`data-settings-panel="${group}"`));
	}
	assert.equal((markup.match(/data-settings-category=/g) ?? []).length, 7);
	assert.match(markup, /data-settings-category="storage"[^>]*aria-pressed="true"/);
	assert.match(markup, /data-settings-group="downloads"[^>]*aria-current="page"/);
	assert.doesNotMatch(markup, /data-settings-panel="downloads" hidden=""/);
	assert.match(markup, /data-settings-panel="general" hidden=""/);
});

test('unknown settings group falls back to general', async () => {
	const markup = await renderSettings('not-a-group');
	assert.match(markup, /data-settings-category="general"[^>]*aria-pressed="true"/);
	assert.doesNotMatch(markup, /data-settings-panel="general" hidden=""/);
});

test('library organization and source lists are real settings panels', async () => {
	const markup = await renderSettings('library');
	assert.match(markup, /data-settings-category="library"[^>]*aria-pressed="true"/);
	assert.doesNotMatch(markup, /data-settings-panel="library" hidden=""/);
	const sources = await renderSettings('source-lists');
	assert.match(sources, /data-settings-category="sources"[^>]*aria-pressed="true"/);
	assert.doesNotMatch(sources, /data-settings-panel="source-lists" hidden=""/);
});
