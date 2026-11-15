# Source-list refresh: independent handoff

Draft PR #2 was reviewed and integrated with the latest native desktop work in
`feat/native-macos-setup`, together with draft PR #3. See
[final integration review](INTEGRATION_REVIEW.md) for verified results and remaining
release gates. Neither this integration nor these instructions merge PR #1 into
`main` or publish a release.

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

A restored authenticated WebKit session also schedules bootstrap. Initialization
is serialized per manager, while the scheduling lock stays independent of network
work. Failure leaves the marker absent and retries at most once a minute while
signed in. A desktop event invalidates repository queries without replacing the
web document or losing a selected import file. Source Lists reports deferred setup
when the list is unavailable.

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
server conservatively updates only enabled external packages from their original
repository, with **zero** registered manga rows and no breaking change. It checks
module validity without executing candidate code, retains stored settings, and
rechecks opt-in, version, origin and references in the metadata write transaction. Any source referenced by manga is left intact
for the existing manually approved update/migration flow. The UI must
explain this distinction; automatic catalog refresh may show an update
even when package installation requires manual approval. There is
no automatic manga-chapter download.

These preferences live in the local settings database and are distinct
from application self-updates. The existing per-list refresh endpoints
and manual source Update All route remain in place. The integrated UI
connects separate toggles to the preferences endpoint, a manual
Check for Source Updates action to repo refresh, and confirmed Update All to the
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

The original GitHub-only draft had not been run. Integration testing now covers
preference contracts, offline cache retention, used-source protection, rejected
packages and deterministic reference/opt-out races. The integration fixed its
missing OpenAPI entry, malformed-body response, authenticated-session gap,
origin selection and source-update controls. Exact suite and native verification
results are recorded in the linked integration review.

## Merge sequencing

The reviewed PR heads are merged into the native feature branch. Follow-up fixes
and validation belong to that branch. PR #1 remains the approval boundary for
`main`; release publication and unsigned automatic app installation remain blocked.
