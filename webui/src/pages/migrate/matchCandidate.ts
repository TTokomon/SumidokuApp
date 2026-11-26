type Candidate = { sourceId: number; key: string; title: string; authors: string[] | null };

function normalize(value: string): string {
	return value.normalize('NFKC').toLowerCase().trim().replace(/\s+/g, ' ');
}

/** A search result is a suggestion, never proof. Refuse unrelated/ambiguous titles. */
export function uniqueTitleMatch<T extends Candidate>(origin: Candidate, candidates: T[]): T | undefined {
	const title = normalize(origin.title);
	if (!title) return undefined;
	const authors = new Set((origin.authors ?? []).map(normalize).filter(Boolean));
	const seen = new Map<string, T>();
	for (const candidate of candidates) {
		if (candidate.sourceId === origin.sourceId && candidate.key === origin.key) continue;
		if (normalize(candidate.title) !== title) continue;
		const names = (candidate.authors ?? []).map(normalize).filter(Boolean);
		if (authors.size && names.length && !names.some((name) => authors.has(name))) continue;
		seen.set(`${candidate.sourceId}:${candidate.key}`, candidate);
	}
	return seen.size === 1 ? [...seen.values()][0] : undefined;
}
