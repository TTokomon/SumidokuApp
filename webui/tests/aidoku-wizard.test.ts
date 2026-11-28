import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';

test('Aidoku wizard presents a plain-language summary and current step', async () => {
	const vite = await createServer({ root: fileURLToPath(new URL('../', import.meta.url)), configFile: false, logLevel: 'silent', appType: 'custom', server: { middlewareMode: true } });
	try {
		const i18n = (await vite.ssrLoadModule('/src/i18n')).default;
		await i18n.changeLanguage('en');
		const { AidokuProgressReview, AidokuWizardSteps, AidokuWizardSummary } = await vite.ssrLoadModule('/src/pages/settings/AidokuImportWizard.tsx');
		const steps = renderToStaticMarkup(createElement(AidokuWizardSteps, { step: 2 }));
		assert.match(steps, /aria-current="step"[^>]*>.*Restore sources/);
		const result = { dryRun: true, imported: { library: 76, progress: 4011, categories: 10, trackers: 42 }, missingSources: ['en.unavailable'], skipped: [] };
		const summary = renderToStaticMarkup(createElement(AidokuWizardSummary, { result }));
		assert.match(summary, /Your backup is ready/);
		assert.match(summary, /4,011/);
		assert.match(summary, /Sources needing attention: 1/);
		assert.doesNotMatch(summary, /en.unavailable/);
		assert.match(renderToStaticMarkup(createElement(AidokuWizardSummary, { result: { ...result, dryRun: false } })), /Import complete/);
		const comparison = renderToStaticMarkup(createElement(AidokuProgressReview, {
			result: { ...result, progressDifferences: [
				{ chapterId: 7, mangaTitle: 'Example Manga', chapterTitle: 'Chapter 7', currentPage: 9, currentRead: true, backupPage: 2, backupRead: false, canCorrect: true, protected: false },
				{ chapterId: 8, mangaTitle: 'Example Manga', chapterTitle: 'Chapter 8', currentPage: 6, currentRead: false, backupPage: null, backupRead: null, canCorrect: false, protected: true },
			] }, selected: [], onChange: () => {}, disabled: false
		}));
		assert.match(comparison, /Sumidoku — Page position 9 · Read/);
		assert.match(comparison, /Aidoku — Page position 2 · Unread/);
		assert.match(comparison, /Page unknown · Read status unknown/);
		assert.equal((comparison.match(/type="checkbox"/g) ?? []).length, 1);
		assert.doesNotMatch(comparison, /checked=/);
	} finally { await vite.close(); }
});
