import { migrateLookup } from '../../api/hooks';
import type { LibraryEntry, SearchManga } from '../../api/types';

export async function searchDestinations(manga: Pick<LibraryEntry, 'id' | 'sourceId' | 'key'>, destinations: number[], signal: AbortSignal, query?: string) {
	const candidates = new Map<string, SearchManga>();
	const failures: number[] = [];
	// One request per row at a time. The caller limits concurrent rows to three.
	for (const sourceId of destinations) {
		if (signal.aborted) break;
		try {
			const result = await migrateLookup(manga.id, sourceId, query, signal);
			if (result.degraded) failures.push(sourceId);
			for (const candidate of result.candidates) {
				if (candidate.sourceId !== sourceId || (sourceId === manga.sourceId && candidate.key === manga.key)) continue;
				candidates.set(`${sourceId}:${candidate.key}`, candidate);
			}
		} catch {
			if (!signal.aborted) failures.push(sourceId);
		}
	}
	return { candidates: [...candidates.values()], failures };
}
