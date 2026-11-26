import assert from 'node:assert/strict';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';
import type { AidokuImportResponse } from '../src/api/types.ts';

test('Aidoku import displays merge, skipped entries with reasons, and unsupported data', async () => {
	const vite = await createServer({
		root: fileURLToPath(new URL('../', import.meta.url)),
		configFile: false,
		logLevel: 'silent',
		appType: 'custom',
		server: { middlewareMode: true }
	});
	try {
		const { default: i18n } = await vite.ssrLoadModule('/src/i18n');
		await i18n.changeLanguage('en');
		const { AidokuImportReport } = await vite.ssrLoadModule('/src/pages/settings/AidokuImportReport.tsx');
		const report: AidokuImportResponse = {
			dryRun: true,
			imported: { library: 1, categories: 1, progress: 1, trackers: 0 },
			included: [{ section: 'library', mangaTitle: 'Example manga', sourceKey: 'en.source', mangaKey: '11' }],
			categoryNames: ['Reading'],
			skipped: [
				{ section: 'progress', sourceKey: 'en.missing', mangaKey: '42', chapterKey: '7', chapterTitle: 'Opening', reason: 'source not installed' },
				{ section: 'trackers', mangaTitle: 'Example manga', sourceKey: 'en.source', mangaKey: '11', trackerId: 'shikimori', reason: 'tracker not supported' }
			]
		};
		const render = (result: AidokuImportResponse) => renderToStaticMarkup(createElement(AidokuImportReport, { result }));
		const preview = render(report);
		assert.match(preview, /Import preview/);
		assert.match(preview, /Will add or merge/);
		assert.match(preview, /<li>Example manga \(en\.source\/11\)<\/li>/);
		assert.match(preview, /Will skip \(2 entries\)/);
		assert.match(preview, /en\.missing\/42 · Opening \(7\).*exact source ID is not installed/);
		assert.match(preview, /Example manga .*shikimori.*does not support this tracker/);
		assert.match(preview, /Outside this import/);
		assert.match(preview, /downloaded chapter files do not transfer/);
		const legacyResult = render({ dryRun: false, imported: report.imported, skipped: [] });
		assert.match(legacyResult, /Import results/);
		assert.match(legacyResult, /Included in the merge/);
		assert.match(legacyResult, /No entries were skipped/);
	} finally {
		await vite.close();
	}
});
