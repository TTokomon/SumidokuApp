// Test-only tracker transport; no provider credentials or live OAuth requests.
localStorage.setItem('sumidoku.language', 'en');
window.__trackerFixture = { connected: true, defaultTracker: null, bindings: [{ mangaId: 1, mangaTitle: 'Fixture Binding', provider: 'anilist', trackId: 'fixture-entry', title: 'Fixture Entry', trackMode: 'auto', chapterOffset: 0, createdAt: 1, updatedAt: 1 }] };
const fixtureFetch = window.fetch.bind(window);
window.fetch = async function(input, options) {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    if(url.origin !== location.origin) throw new Error('Non-local network disabled in native fixture');
    const state = window.__trackerFixture;
    const reply = body => Promise.resolve(new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    if (/\/trackers\/oauth\/[^/]+\/status$/.test(url.pathname)) return reply({ logged_in: url.pathname.includes('/anilist/') && state.connected, username: url.pathname.includes('/anilist/') && state.connected ? 'Fixture User' : null });
    if (/\/trackers\/oauth\/[^/]+\/logout$/.test(url.pathname)) { state.connected = false; state.defaultTracker = null; return reply({}); }
    if (url.pathname.endsWith('/trackers/preferences')) {
        if(options?.method === 'PUT') state.defaultTracker = JSON.parse(options.body).defaultTracker;
        return reply({ defaultTracker: state.defaultTracker });
    }
    if(url.pathname.endsWith('/trackers/links')) return reply({ entries: state.bindings, totalPages: state.bindings.length ? 1 : 0, hasNextPage: false, counts: { manga: state.bindings.length, providers: { anilist: state.bindings.length } } });
    if(/\/trackers\/links\/\d+\/anilist$/.test(url.pathname) && options?.method === 'DELETE') { state.bindings = []; return reply({}); }
    return fixtureFetch(input, options);
};
