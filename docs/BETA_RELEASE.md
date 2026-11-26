# Desktop community distribution, Beta and Restore Stable

Desktop releases use public GitHub Releases and Sparkle Ed25519 signatures. An
Apple Developer Program membership is **not required**. Developer ID signing and
notarization remain an optional `developer-id` distribution policy. Neither a
certificate nor notarization is a release blocker for `community` mode.

## First installation

Download the Apple silicon ZIP and `SHA256SUMS` from the public
[Stable 1.3.0+community.1 (build 9)](https://github.com/TTokomon/SumidokuApp/releases/tag/desktop-v1.3.0%2Bcommunity.1)
release and verify the ZIP against the inventory. Extract Sumidoku.app and drag it into Applications. The native app
contains the matching server; it keeps an existing managed library and service.
Do not overwrite an existing installation until its backup and compatibility have
been reviewed. The original 1.3.0 (6) cannot perform this bootstrap itself.

A community build is ad-hoc signed, without Apple's notarization. macOS may block
its first launch. Attempt to open the app, then use **System Settings → Privacy &
Security → Open Anyway** for Sumidoku and confirm the per-application prompt.
See [Apple's instructions](https://support.apple.com/en-us/102445). Do not disable
Gatekeeper globally or remove quarantine with a script. A damaged-app warning is
not proof that an archive is safe: verify the published checksum and origin first.
Managed Macs may prohibit exceptions; that is an administrator policy, not a paid
signing prerequisite for the community release stream.

## Explicit trust policies

`SUMIDOKU_DISTRIBUTION_MODE=community` builds a publisher-authenticated application:

- The Ed25519 public key is compiled into the client and helper and also recorded
  in Info.plist. The private key is never compiled or committed. Local signing
  uses Sparkle's Keychain account `app.sumidoku.desktop.community.release`;
  protected CI uses `DESKTOP_SPARKLE_PRIVATE_KEY` through stdin only.
- The exact catalog bytes are authenticated before interpreting versions, hashes,
  schema or download URLs. Appcast XML carries Sparkle's embedded signature.
- Archive length, SHA-256 and Ed25519 signature are checked before extraction.
  Bounded downloads use HTTPS and explicitly allowed redirect destinations.
  Existing ZIP traversal, duplicate path, symlink and expansion defenses remain.
- A separately Ed25519-signed bundle inventory authenticates paths, permissions,
  file contents and symlink destinations, including the helper, server and native
  trust root. Only the main executable's trailing Apple signature envelope and
  its size fields are normalized to avoid a circular resource seal. Code and the
  signature offset remain bound. Ad-hoc `codesign --verify --deep --strict` still
  checks bundle integrity; it is not treated as publisher identity.
- A missing/wrong key, invalid seal, unknown policy or silent change of key,
  policy, feed or catalog leaves installation unavailable. Info.plist flags alone
  cannot enable installation. Community verification does not call `spctl` to
  demand Developer ID acceptance.

`SUMIDOKU_DISTRIBUTION_MODE=developer-id` instead requires the configured Apple
team, Developer ID requirement, Gatekeeper assessment and stapled notarization.
Changing between policies is an explicit bootstrap/review, not a silent update.

## Stable baseline and provenance

The existing installed **1.3.0 (6)** remains untouched and is not republished with
invented provenance. Its recorded backend revision is `9fd09f5`, schema 37. Its
recorded source-tree digest does not equal that commit's tracked tree.

The public updater bootstrap is **1.3.0+community.1 (build 9)**.
The authenticated [desktop update feeds](https://github.com/TTokomon/SumidokuApp/releases/tag/desktop-updates)
reference this exact Stable archive. `macos/Distribution/assemble-stable-bootstrap.py` overlays only updater
support on a clean, separate worktree at the audited Stable revision. The Stable
DesktopShell, web interface, logo and existing preferences remain at that base.
The assembly receipt records both the base and updater overlay. Current Beta UI
must never be renamed 1.3.0. The exact resulting app/server hashes and schema must
be qualified in `stable-baselines.json` before Stable packaging is permitted.
An isolated test using a reused backend is evidence about that specific binary,
not a claim of a clean-source public rebuild.

## Build and packaging

The manual desktop-only candidate workflow defaults to `community`, uses the
protected `desktop-community` environment and does not invoke the Cargo/server/
Docker release publisher. Apple certificate and notarization steps run only in
optional `developer-id` mode. Its `contents: read` permission cannot publish.

Configure the public key, trusted HTTPS appcast and catalog URLs before building:
`SUMIDOKU_UPDATE_PUBLIC_KEY`, `SUMIDOKU_UPDATE_FEED`,
`SUMIDOKU_RELEASE_CATALOG`, `SUMIDOKU_RELEASE_BUILD=1`, numeric
`SUMIDOKU_BUILD_NUMBER` and full `SUMIDOKU_RELEASE_VERSION`. The normal build is
`macos/build-fork.sh`; native-only packaging is `macos/build-app.sh`. Neither
command installs unless an explicitly supported installation option is supplied.
Use `SUMIDOKU_CERTIFIED_COORDINATION=1` only for an approved, qualified artifact;
the candidate workflow defaults it off; enabling an unpublished qualification candidate does not authorize publication.

`macos/Distribution/prepare-release.sh APP OUTPUT [--previous-catalog FILE]`
verifies the selected trust policy and emits an unpublished ZIP, SHA256SUMS,
release notes, signed JSON catalog and signed Sparkle appcast. Beta requires a
previous authenticated Stable catalog. Dirty/mixed-source Beta artifacts, unknown
Stable provenance, test-scope builds and existing output directories are refused.
Versions use `desktop-vVERSION` tags and
`Sumidoku-Desktop-VERSION-macOS-arm64.zip`; Beta releases set `prerelease=true`.
Never replace an existing version's archive. Preserve Stable entries in both feeds.

GitHub release listings provide discovery; they are not installation authority.
Feed hosting and publication must be verified before enabling public installation.
Publication remains separate from building: do not publish test keys, fixture
builds or an unqualified Beta. Review the final signed artifacts and the complete
qualification evidence before approval. No release or tag is created by the
candidate workflow.

## Coordinated installation and Restore Stable

The native helper independently validates the app, saved library descriptor,
runner, LaunchAgent arguments and the single owned localhost listener. It does not
control arbitrary servers. WKWebView is quiesced before a private stdin-only
session handoff. A cold configuration/service snapshot and durable journal precede
atomic runtime replacement and application swap. The same managed job restarts;
health, existing authentication, database integrity and logical durable state are
checked. The real relaunched application's loaded window must acknowledge the
version and authenticated session. Quitting normally never stops the server.

The previous authenticated Stable pair and signed catalog are retained. **Restore
Stable** requires confirmation, the exact retained pair, matching feature set and
compatible current schema. It keeps the current database, accounts, subscriptions,
reading progress and downloads. It does not restore an old database snapshot.
Changing the channel alone never downgrades. Failed handoff restores the sealed
previous app/server; changed data or an unquiesced app stops for manual recovery.
No application update schedules manga downloads or disables backups.

## Release-critical verification

Run the native policy/security and packaging suites once after implementation.
Test actual isolated app bundles through Stable → Beta → Restore Stable, including
helper exit/relaunch acknowledgement, signed packages and preserved user fixtures.
The compiled `COMMUNITY_E2E` scope has its own key, bundle identifier, home,
LaunchAgent and port; production binaries have no test redirect/command channel.
Fixture downloads use authentic signed bytes locally; this does **not** certify
GitHub's live HTTPS feed redirects or a first-install Gatekeeper exception.
Packaging explicitly refuses those fixture bundles.

Required negatives include wrong key/seal, corruption, traversal, unsafe redirects,
offline repositories, failed handoff, interruption and schema incompatibility.
Record exact artifact hashes, test results and unrun gates. Complete existing
release CI requirements on the reviewed head before publication; paid Apple
signing checks apply only if that optional policy is selected.

## Verification recorded for community mode

The native community test passed with real SwiftUI/WKWebView application bundles,
the bundled helper, actual LaunchAgent-managed backends and Ed25519-signed archives:
**1.3.0+community.1 (9) → 1.3.1-beta.1 (10) → 1.3.0+community.1 (9)**.
It checked the authenticated native window acknowledgement, single listener,
current account, persistent WKWebView cookies without re-injecting login credentials,
library, local source, reading progress advanced during Beta,
a completed CBZ download and its database row, existing backup and enabled backup
schedule. The disposable service was removed afterward. No original application,
user library or managed service was replaced.

The exercise caught and corrected equivalent filesystem-alias comparisons in the
archive/helper/relaunch path, and stale pending-handoff UI after the helper recorded
`verified`. Restore Stable becomes available without reopening the application.
Native policy checks passed 48 assertions, archive/recovery checks 52, actual
native bundle seal checks 11, and Python packaging/publication/build guards 52 tests.
The build 10 qualification below records the fresh suite results and the reviewed
application CI. The original packaging and rollback evidence remains tied to the
exact app and server payloads tested.

Production public-key configuration is recorded in
`macos/Distribution/community-release-public-key.txt`. The private signing key
remains in the dedicated local Keychain account. The published Stable baseline
uses the audited base with its sealed updater-only overlay. Build 10 uses the
clean app and backend pair from `6f92874`.

## Default free publication route: keep the private key on the Mac

Local signing is sufficient; exporting the signing key to GitHub is **optional**.
The `desktop-local-draft.yml` workflow creates only an empty, unpublished desktop
draft after maintainer approval. It creates the tag/release through CI, independently
of the server/Docker publisher. It does not need a signing secret.

After all qualification checks pass, prepare the artifact set locally with Keychain.
Create and sign its exact qualification document as described in
`macos/Distribution/qualifications/README.md`. Use
`publish_release.py ARTIFACTS --trust-tool TOOL --stage-local` to upload only public
signed artifacts to the matching CI-created draft. This command refuses published
releases and wrong-source drafts; it never creates a tag or publishes a release.

With the matching `staged_tag`, run `desktop-publish.yml` with `verify_only=true`
and `policy_test=false` to authenticate the unpublished draft. The publication
job is skipped. Only a separate approved run from `main` with `verify_only=false`
can publish, following `desktop-release` environment approval. Alternatively,
the workflow can consume `candidate_run_id` from the optional CI-signing route.
Supply exactly one artifact input. Publication requires an Ed25519-signed qualification binding the precise
version, build, archive, catalog, appcast and checksum inventory. The archive is
re-authenticated and safely extracted for production policy verification. Prior
published entries are preserved; Beta cannot publish before an authenticated
published Stable feed exists. Publication never installs an application.

The optional CI-signing route needs separately authorized credential provisioning.
Build/compiler processes reject a production signing seed in their environment;
community sealing happens afterward in its own step. Verification children do not
inherit a CI seed, and `sign_update` receives it only through stdin. Both community
and publication environments require maintainer approval. No production private
key has been exported in this verification.

The manual workflows are registered on `main`. Protected draft creation at a
historical source requires the short-lived release credential described in the
[desktop publication runbook](DESKTOP_PUBLICATION.md). Create desktop drafts
through the protected workflow.

## Build 10 qualification against the public Stable baseline

The corrected `1.3.1-beta.1` archive retains the production app and server code
from `6f92874` and both original source receipts. The publisher seal and ad-hoc
signature envelope were refreshed to include the original Sumidoku MIT license.
Sparkle's notice and every other unsigned payload were preserved. The local
Keychain signed the archive, appcast, catalog and exact qualification.

- Beta ZIP SHA-256: `072298f4c8bce6fb136d7e303e1a48259561887df4c10106163b9e4a41290aa6`.
- Public Stable ZIP SHA-256: `d445eaa7e72f355cedfa0cb6924d4b80f3cec379860ba62e250a33acd7b77340`.
- The public Stable assets and all three update feed files matched the approved
  bytes over HTTPS. Stable's signed build 9 entry is unchanged in the Beta catalog.
- [Exact signed qualification](../macos/Distribution/qualifications/desktop-v1.3.1-beta.1.json)
  binds the new archive, catalog, appcast and checksum inventory.

### Fresh qualification results

| Check | Result |
| --- | --- |
| Rust workspace | 1,278 passed, 2 skipped across 78 binaries. Includes backup export/restore, source lists, auth, downloads and library progress. Clippy and compilation passed. |
| Formatting | `git diff --check` passed. `cargo fmt --all --check` reported formatting differences in 219 unchanged Rust files. No Rust source was edited in this PR. |
| Frontend | 380 passed. TypeScript and production web build passed. |
| Python | 52 macOS tests and 37 publication tests passed. |
| Swift and native | 12 navigation cases, 48 update/material assertions, 52 release-security/recovery assertions, 9 source-bootstrap assertions, 32 isolated onboarding assertions, and 11 production bundle-seal checks passed. All 11 native destinations resolved, with 13 unique current and 13 unique fallback symbols. Welcome view rendering passed. |
| Disposable WKWebView | Passed 11 destinations, 9 legacy routes, both footer controls, Settings persistence, library organization and Aidoku recovery. Tracker UI used a local fixture. A follow-up native run captured and verified both light and dark sidebar appearances. |
| Actual native fixture round trip | Stable build 9 → Beta build 10 → Restore Stable build 9 passed with the exact release server binaries. Preserved persisted WKWebView login, current library and advanced progress, local source, external subscription and source settings, existing download and backup, and backup schedule. No extra download jobs were created. |
| Exact production package | Swift archive verification, Ed25519 archive/catalog/qualification verification, signed appcast, SHA256SUMS, both license notices, strict ad-hoc signature and publisher inventory passed. |

The first fresh round trip timed out at the harness's 100-second handoff deadline
and recovered to the prior Stable app. A reset disposable run with a 300-second
deadline verified both transitions. Fixture transport uses real signed ZIPs and
does not claim live download of the unpublished Beta or Gatekeeper first-launch
certification. The final production bundle was verified separately and was never
installed. The nonce-scoped fixture service was removed after testing.

The native sidebar harness now reads actual candidate bundle metadata and uses a
temporary localhost port, checking that the disposable child owns the listener
before making requests. The round trip checks source-list persistence
and rejects any download rows beyond the known completed fixture. The runtime
source and prior reviewed application CI remain unchanged.

The protected draft workflow on `main` rejected historical-source draft creation
with HTTP 403 in [run 44254832530](https://github.com/TTokomon/SumidokuApp/actions/runs/44254832530).
The reviewed path uses the short-lived `DESKTOP_RELEASE_TOKEN` in the single
protected draft-creation step and pins both version and source to main's policy.
GitHub staging and remote read-only validation follow review and merge of those
changes. No manual release creation substitutes for the protected workflow.

## Beta 2 (build 11)

Beta 2 includes the Aidoku import report from [PR #11](https://github.com/TTokomon/SumidokuApp/pull/11). A preview lists included library entries, categories, chapter progress and tracker bindings, identifies skipped rows with reasons, and explains what this importer leaves out. Its result uses the same report layout after the merge. The database schema and source matching rules are unchanged.

The app and server were built from `17132f9542ea569c8cddac8820796dd19ec1f5c8`, whose Git tree equals the independently tested PR head `4ac9fed14f053e289b262f4ec60f1da66b89a43e`. [Reviewed CI](https://github.com/TTokomon/SumidokuApp/actions/runs/45752225377) passed. The [signed qualification](../macos/Distribution/qualifications/desktop-v1.3.1-beta.2.json) records the exact archive and validation evidence.

A disposable native Stable 9 to Beta 11 upgrade and Restore Stable returned to build 9 with both exact release server binaries. It preserved account access, reading progress, source settings, downloads, backups and the backup schedule. The production server also passed a synthetic Aidoku import, with the preview matching the committed report. The signed candidate catalog selects build 11 on Beta and build 9 on Stable, and both existing release entries and appcast items are preserved.
