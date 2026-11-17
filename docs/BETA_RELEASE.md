# Desktop community distribution, Beta and Restore Stable

Desktop releases use public GitHub Releases and Sparkle Ed25519 signatures. An
Apple Developer Program membership is **not required**. Developer ID signing and
notarization remain an optional `developer-id` distribution policy. Neither a
certificate nor notarization is a release blocker for `community` mode.

## First installation

Use only the desktop ZIP attached to a verified release in
[TTokomon/SumidokuApp](https://github.com/TTokomon/SumidokuApp/releases), and check
its SHA256SUMS. Extract Sumidoku.app and drag it into Applications. The native app
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

The updater bootstrap is distinctly named **1.3.0+community.1**, with its own build
number. `macos/Distribution/assemble-stable-bootstrap.py` overlays only updater
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
the candidate workflow deliberately leaves it off until qualification.

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
current account, library, local source, reading progress advanced during Beta,
a completed CBZ download and its database row, existing backup and enabled backup
schedule. The disposable service was removed afterward. No original application,
user library or managed service was replaced.

The exercise caught and corrected equivalent filesystem-alias comparisons in the
archive/helper/relaunch path, and stale pending-handoff UI after the helper recorded
`verified`. Restore Stable becomes available without reopening the application.
Native policy checks passed 48 assertions, archive/recovery checks 52, actual
native bundle seal checks 11, and Python packaging/publication guards 45 tests.
Frontend/Rust sources did not change in this work; reuse passing evidence for those
unchanged inputs instead of repeatedly rebuilding them. The preceding CI run's
Rust tests, Clippy and web checks passed; its macOS build was cancelled because no
hosted runner could acquire the job. A new reviewed-head CI result remains required.

Production public-key configuration is recorded in
`macos/Distribution/community-release-public-key.txt`. The production private key
was created in the dedicated local Keychain account. Public GitHub variables and
maintainer approval environments are configured; the private key has **not** been
exported to GitHub Actions. CI signing needs explicit approval for that credential
transfer, or continued local signing. No desktop tag or public release was created.
The first public Stable artifact still needs exact-artifact qualification and the
complete release gate; fixture success alone does not publish or qualify an archive.
