import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { createServer } from 'vite';
const root=fileURLToPath(new URL('../',import.meta.url));
test('native navigation bridge accepts only local application routes',async()=>{
	const vite=await createServer({root,configFile:false,appType:'custom',logLevel:'silent',server:{middlewareMode:true}});
	try {
		const { validDesktopRoute, desktopHost }=await vite.ssrLoadModule('/src/native/DesktopBridge.tsx');
		for(const route of ['/library','/reader/42','/settings?section=source-lists'])assert.equal(validDesktopRoute(route),true);
		for(const route of ['https://example.com','//example.com','/\\example.com',null,42,'x'.repeat(3000)])assert.equal(validDesktopRoute(route),false);
		assert.equal(desktopHost(),undefined);
	}finally{await vite.close();}
});
test('web surfaces remain opaque and accessibility modes preserve readable content',()=>{
	const css=readFileSync(new URL('../src/styles/desktop.css',import.meta.url),'utf8');
	assert.doesNotMatch(css,/backdrop-filter\s*:|blur\(/);
	assert.match(css,/prefers-reduced-motion/);assert.match(css,/prefers-contrast/);assert.match(css,/prefers-reduced-transparency/);
	assert.match(css,/data-native-shell/);assert.match(css,/--font-display: var\(--font-sans\)/);
});

test('native shell avoids duplicate category navigation and preserves searchable subsections', () => {
	const css = readFileSync(new URL('../src/styles/desktop.css', import.meta.url), 'utf8');
	const settingsRule = css.match(/\[data-native-shell='true'\] \.settings-nav\s*\{([^}]*)\}/)?.[1] ?? '';
	assert.match(settingsRule, /display:\s*none/);
	assert.match(css, /\[data-native-shell='true'\] \.app__sidebar/);
});
