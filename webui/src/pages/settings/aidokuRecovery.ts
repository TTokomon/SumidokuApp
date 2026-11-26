/** Display names are presentation only; installs and matching always use the original exact key. */
const names: Record<string, string> = {
	'en.asurascans': 'Asura Scans',
	'en.flamecomics': 'Flame Comics',
	'en.mangabat': 'MangaBat',
	'en.mangadistrict': 'MangaDistrict',
	'en.omegascans': 'OmegaScans',
	'en.toonily': 'Toonily',
	'en.weebcentral': 'WeebCentral',
	'multi.mangadex': 'MangaDex',
	'multi.mangafire': 'MangaFire',
	'multi.webtoon': 'Webtoon'
};

export function aidokuSourceLabel(key: string): string {
	const fallback = key.split('.').pop() || key;
	return names[key] ?? (fallback.charAt(0).toUpperCase() + fallback.slice(1));
}

/** Select only unambiguous, not-yet-installed exact matches. Multiple lists require a user choice. */
export function defaultRecoverySelection(matches: { key: string; repoId: number; installedId: number | null }[]): string[] {
	const groups = new Map<string, Set<string>>();
	for (const entry of matches) {
		if (entry.installedId !== null) continue;
		const group = groups.get(entry.key) ?? new Set<string>();
		group.add(`${entry.repoId}:${entry.key}`);
		groups.set(entry.key, group);
	}
	return [...groups.values()].filter((group) => group.size === 1).map((group) => [...group][0]).sort();
}
