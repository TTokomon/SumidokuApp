import assert from 'node:assert/strict';
import test from 'node:test';
import { uniqueTitleMatch } from '../src/pages/migrate/matchCandidate.ts';

const origin = { sourceId: 1, key: 'old', title: 'Example Story', authors: ['Author'] };
const correct = { sourceId: 2, key: 'right', title: 'EXAMPLE  STORY', authors: ['Author'] };
const wrong = { sourceId: 2, key: 'sequel', title: 'Example Story 2', authors: ['Author'] };

test('migration never chooses the first unrelated search result', () => {
	assert.equal(uniqueTitleMatch(origin, [wrong, correct]), correct);
	assert.equal(uniqueTitleMatch(origin, [wrong]), undefined);
	assert.equal(uniqueTitleMatch(origin, [{ ...correct, authors: ['Someone else'] }]), undefined);
});

test('ambiguous exact titles require manual selection; same identity cannot be selected', () => {
	assert.equal(uniqueTitleMatch(origin, [correct, { ...correct, key: 'different-edition' }]), undefined);
	assert.equal(uniqueTitleMatch(origin, [origin]), undefined);
	assert.equal(uniqueTitleMatch(origin, [correct, correct]), correct);
});
