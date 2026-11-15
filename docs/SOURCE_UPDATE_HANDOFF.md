# Source-list refresh: independent handoff

This work lives on `feat/community-source-refresh`, branched from PR #1's
`526702bc889cb05eff3e9fa987ac1a109b3d1105`. It has **not** been merged,
built, or installed on the user's Mac by this change.

## Default community subscription

After a successful, authenticated local library creation or Sign In,
the native client checks the existing `GET /api/v1/source-repos` list
and subscribes to `https://aidoku-community.github.io/sources/index.min.json`
using the existing protected `POST /api/v1/source-repos` endpoint.

This runs on a background queue so a network outage does not invalidate
local owner creation or existing-library connection. The client writes
`Server/.aidoku-community-list-initialized` with private permissions
only after confirming that the community list is already subscribed or
successfully added. The marker means intentionally removing that list
does **not** silently re-add it at the next sign-in. Without the marker,
offline failures retry on a future authenticated local connection.
The subscription does **not** install any source packages or chapters.

Important UX limitation: the list may appear moments after sign-in,
because discovery/index downloading is asynchronous. The redesigned
Source Lists UI should surface this state and refresh its queries after
subscription. An existing authenticated WebKit session that bypasses
native Sign In will not trigger the bootstrap immediately; it will run
at the next explicit native sign-in. Consider adding an authenticated
one-time client check on launch if this gap matters.

## Source-list refresh and optional package updates

Existing source-list index refresh was already scheduled once per hour
in the fork's server config, with cached entries retained on fetch failures.
The new preferences default to:

- `autoRefreshLists: true`: scheduled catalog checks are enabled
- `autoUpdatePackages: false`: **no** unattended source-package replacement

Authenticated JSON API:

- `GET /api/v1/source-repos/preferences` returns both booleans
- `PUT /api/v1/source-repos/preferences` accepts both booleans

Example request:

```json
{"autoRefreshLists":true,"autoUpdatePackages":false}
```

When users explicitly enable automatic source-package updates, the
server conservatively updates only external packages with **zero**
registered manga rows. Any source referenced by manga is left intact
for the existing manually approved update/migration flow. The UI must
explain this distinction; automatic catalog refresh may show an update
even when package installation requires manual approval. There is
no automatic manga-chapter download.

These preferences live in the local settings database and are distinct
from application self-updates. The existing per-list refresh endpoints
and manual source Update All route remain in place. The redesigned UI
should connect separate toggles to the preferences endpoint, a manual
Check for Source Updates action to repo refresh, and Update All to the
existing explicit route, showing individual failures and migration warnings.

## Integration and review gates

Run on the Mac **before** merging this branch:

```sh
cargo fmt --all --check
cargo nextest run --workspace
cargo clippy --workspace --all-targets -- -D warnings
cd webui && npm run check && npm test && npm run build
cd ..
./macos/test-app.sh
./macos/test-onboarding.sh
```

Also check:
- Fresh onboarding eventually shows Aidoku Community, without installing packages
- Existing library with the list does not duplicate it
- Explicit removal survives sign-out/sign-in and app restart
- Offline setup completes and retries subscription later
- Automatic index refresh detects new source versions and preserves cached entries on failures
- Default package auto-update setting is off
- Explicit opt-in does not auto-replace sources with registered manga
- Full library data, downloads, settings, and credentials are unchanged
- OpenAPI/API contract and generated schema compatibility for the new preferences endpoint

**Testing limitation:** This branch was edited through GitHub. No Rust,
Xcode or runtime test suite was executed in this environment; the
regression test is committed but needs to run on the user's Mac.

## Merge sequencing

Codex should keep native visual/toolbar/Sparkle changes on its own branch
based on the current PR #1. After both branches pass their tests,
integrate them in sequence, resolving `LibraryManager.swift` only if
Codex changed onboarding. Do not merge into `main`, publish releases,
or alter the installed macOS app without user approval.
