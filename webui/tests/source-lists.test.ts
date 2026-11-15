import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { createServer } from 'vite';

async function modules() {
	const vite = await createServer({ root: fileURLToPath(new URL('../', import.meta.url)), configFile: false, logLevel: 'silent', appType: 'custom', server: { middlewareMode: true } });
	await vite.ssrLoadModule('/src/i18n');
	return vite;
}
function render(component: any, qc = new QueryClient()) {
	return renderToStaticMarkup(createElement(QueryClientProvider, { client: qc }, createElement(MemoryRouter, {}, createElement(component))));
}

test('all four built-in setup options render before sources load and without any repository', async () => {
	const vite = await modules();
	try {
		const { BuiltInSources } = await vite.ssrLoadModule('/src/pages/browse/BuiltInSources.tsx');
		const markup = render(BuiltInSources);
		for (const name of ['Local Files', 'Komga', 'Kavita', 'Suwayomi']) assert.ok(markup.includes(name), name);
		assert.equal((markup.match(/data-integration=/g) ?? []).length, 4);
		assert.match(markup, /No GitHub source list is required/);
	} finally { await vite.close(); }
});

test('Sources separates built-ins from external packages and links to the single Source Lists setting', async () => {
	const vite = await modules();
	try {
		const { default: Browse } = await vite.ssrLoadModule('/src/pages/BrowsePage.tsx');
		const qc = new QueryClient(); qc.setQueryData(['sources'], []);
		const markup = render(Browse, qc);
		assert.match(markup, /Built-in Sources/); assert.match(markup, /External Sources/);
		assert.match(markup, /Settings → Source Lists/); assert.doesNotMatch(markup, /Add Repository/);
	} finally { await vite.close(); }
});

test('Settings has a dedicated Source Lists section with list management', async () => {
	const vite = await modules();
	try {
		const { SourceLists } = await vite.ssrLoadModule('/src/pages/settings/SourceLists.tsx');
		const { SETTINGS_GROUPS } = await vite.ssrLoadModule('/src/pages/settings/SettingsLayout.tsx');
		assert.ok(SETTINGS_GROUPS.some(([id]) => id === 'source-lists'));
		const markup = render(SourceLists); assert.match(markup, /Source Lists/); assert.match(markup, /Add Source List/);
		assert.match(markup, /Installed packages and repository subscriptions are separate/);
	} finally { await vite.close(); }
});

test('Aidoku recovery matches exact source IDs and never display names', async () => {
	const vite = await modules();
	try {
		const { missingAidokuIds, AidokuSourceRecovery } = await vite.ssrLoadModule('/src/pages/settings/AidokuSourceRecovery.tsx');
		const preview = { dryRun: true, imported: { library: 0, progress: 0, categories: 0, trackers: 0 }, skipped: [
			{ sourceKey: 'en.exact', reason: 'source not installed', section: 'library', mangaKey: '1' },
			{ sourceKey: 'en.exact', reason: 'source not installed', section: 'progress', mangaKey: '1' },
			{ sourceKey: 'en.other', reason: 'unsupported tracker', section: 'trackers', mangaKey: '2' }
		] };
		assert.deepEqual(missingAidokuIds(preview), ['en.exact']);
		const Component = () => createElement(AidokuSourceRecovery, { file: new File(['fixture'], 'original.aib'), preview, onPreview: () => {}, onManageLists: () => {} });
		const markup = render(Component);
		assert.match(markup, /en.exact/); assert.match(markup, /Source names are never used to guess/);
		assert.match(markup, /Recheck Backup/); assert.match(markup, /original backup is unchanged/);
	} finally { await vite.close(); }
});
