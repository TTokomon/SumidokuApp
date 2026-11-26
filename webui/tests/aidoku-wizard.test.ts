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
		const { AidokuWizardSteps, AidokuWizardSummary } = await vite.ssrLoadModule('/src/pages/settings/AidokuImportWizard.tsx');
		const steps = renderToStaticMarkup(createElement(AidokuWizardSteps, { step: 2 }));
		assert.match(steps, /aria-current="step"[^>]*>.*Restore sources/);
		const result = { dryRun: true, imported: { library: 76, progress: 4011, categories: 10, trackers: 42 }, missingSources: ['en.unavailable'], skipped: [] };
		const summary = renderToStaticMarkup(createElement(AidokuWizardSummary, { result }));
		assert.match(summary, /Your backup is ready/);
		assert.match(summary, /4,011/);
		assert.match(summary, /Sources needing attention: 1/);
		assert.doesNotMatch(summary, /en.unavailable/);
		assert.match(renderToStaticMarkup(createElement(AidokuWizardSummary, { result: { ...result, dryRun: false } })), /Import complete/);
	} finally { await vite.close(); }
});
