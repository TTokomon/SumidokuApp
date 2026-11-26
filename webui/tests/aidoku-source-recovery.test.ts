import assert from 'node:assert/strict';
import test from 'node:test';
import { aidokuSourceLabel, defaultRecoverySelection } from '../src/pages/settings/aidokuRecovery.ts';

test('source recovery preselects unique exact packages only', () => {
	assert.deepEqual(defaultRecoverySelection([
		{ key: 'en.weebcentral', repoId: 1, installedId: null },
		{ key: 'multi.mangadex', repoId: 1, installedId: null },
		{ key: 'multi.mangadex', repoId: 2, installedId: null },
		{ key: 'en.mangabat', repoId: 1, installedId: 12 }
	]), ['1:en.weebcentral']);
	assert.equal(aidokuSourceLabel('en.weebcentral'), 'WeebCentral');
	assert.equal(aidokuSourceLabel('en.missing'), 'Missing');
});
