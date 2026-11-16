# Desktop Stable/Beta releases and Restore Stable

This prepares an unpublished desktop release path. It does **not** certify a
public Beta, authorize publication, replace an installed application or merge PR #4.

## Baseline and current blockers

The preserved Stable baseline is **1.3.0 (6)**, schema 37, with a bundled fork
server from `9fd09f5`. The bundled and managed server hashes match. Its application
signature is ad-hoc, no updater feed/public key/team is configured, and its
coordinated installer is disabled. The recorded build-tree digest does not match
the tracked tree at that revision; the tracked commit alone is not sufficient
reproduction evidence. There are no published desktop Releases in this fork.

No Developer ID Application signing identity is available for this review. A
signed/notarized Stable archive, trusted hosted catalog/appcast, and successful
public-signed GUI round trip therefore remain blocked. No archive pretending to
be an authenticated original Stable release is generated.

Untouched 1.3.0 cannot perform this upgrade itself. A one-time **separately approved
manual bootstrap** of a signed updater-capable Stable build may be needed. Such a
build must implement the native relaunch-acknowledgement protocol (version 1),
preserve the audited Stable UI/backend and document the updater-only
source changes, original recovery artifact and provenance. Rebuilding the current
Beta UI and naming it 1.3.0 is not an acceptable baseline. Stable publication and
bootstrap installation require separate review and approval.

## Release streams and artifacts

`.github/workflows/desktop-candidate.yml` is manual and desktop-only. It accepts an
immutable reviewed source SHA and numeric build number. It does not modify Cargo's
version, create tags/releases, deploy feeds, touch Docker or invoke the existing
server publisher. Its only repository permission is contents read. Signing runs
behind the protected `desktop-signing` environment.

Stable tags use `desktop-v1.3.0`; Beta 1 uses `desktop-v1.3.1-beta.1`. Archive names
are `Sumidoku-Desktop-VERSION-macOS-arm64.zip`. Increasing numeric `CFBundleVersion`
is distinct from the human release version; Beta 1 is planned as build 8. An
existing published version/artifact must never be overwritten.

`macos/Distribution/prepare-release.sh APP OUTPUT [--previous-catalog FILE]`
requires a Developer ID application, Gatekeeper acceptance, a stapled notarization
ticket, pinned public key and trusted HTTPS feed/catalog. It creates a symlink-
preserving archive without Finder/resource-fork metadata, checksum inventory,
release notes, unpublished release plan, signed catalog and signed Sparkle 2
appcast. Beta preparation requires a previously authenticated Stable catalog.
The archive contains the native app, helper and matching signed server manifest.
Stable packaging also requires an exact artifact/provenance record in
`stable-baselines.json`; its qualification list is deliberately empty until the
original/bootstrapped baseline is reviewed. Signing flags cannot manufacture that
qualification.

Stable uses Sparkle's default channel; Beta entries carry `sparkle:channel=beta`.
Opting into Beta includes Stable plus Beta; Stable excludes Beta. The appcast uses
numeric build versions, human short versions and archive Ed25519 signatures.
Sparkle's pinned official `sign_update` signs/verifies archive and appcast bytes.
A companion exact-byte signed JSON catalog uses the same key and binds source,
version, build, schema, client/server hashes and the immutable GitHub asset URL.
Manual preparation retains previous entries instead of overwriting Stable.

Beta packaging also rejects dirty source or client/server provenance from different
commits. Native build receipts record the source revision/tree digest, while the
server manifest records its own build inputs. The local development review may
reuse an unchanged backend; it cannot be packaged as an exact-source public Beta.

The build and publication are separate. Candidate signing alone is not release
qualification. The candidate workflow leaves coordination certification off;
qualifying an unpublished signed test build in an isolated macOS account/VM must
precede any enabled production artifact or release approval.

## Native installation and recovery

- `ReleaseTrust.swift` authenticates the catalog before decoding installation
  metadata. Downloads are bounded and use explicit HTTPS redirect hosts. GitHub
  API release listings provide discovery only, never installation authority.
- `ArchiveValidation.swift` authenticates archive length/hash/Ed25519 signature
  before extraction, rejects unsafe/duplicate paths, symlink escapes/ancestors,
  malformed local/central directory names and expansion limits. No package script
  or repository code is executed. Only full app ZIPs are supported.
- `NativeUpdateInstaller.swift` binds the current app, library and managed service,
  verifies actual Developer ID/Gatekeeper trust and explicit release provisioning,
  and offers a confirmed handoff. An Info.plist flag alone cannot enable installs.
  Unattended installation remains disabled. No manga download is scheduled.
- `SumidokuUpdateHelper` is a native bundled executable; production installation
  needs no Python, Xcode or command-line developer tools. The helper revalidates
  signed metadata, the payload, descriptor and owned job. It receives the existing
  login cookie over an anonymous pipe, never in a request file, command argument,
  preference, source file or log. The app closes its WebKit document before quit.
- The helper locks installation, confirms the localhost listener belongs to the
  managed runner, waits for its parent app to exit, stops only that job and waits
  for the port to clear. It journals intent, retains a private verified cold Server
  snapshot, previous application, runtime and LaunchAgent, then replaces runtime
  and atomically swaps application directories. It starts the same job and verifies
  health/authentication, protected data and the relaunched app's window/login ack.
- `PairedInstallation.swift` is the canonical transaction engine. It permits only
  equal schema versions and declared server feature-sets in either direction. No migration, database replacement,
  data rewind or automatic recovery from changed data is attempted. Startup auth
  overrides/unsupported TOML keys are rejected for review instead of silently
  reseeding credentials. Migration checksums are included in data integrity checks. Failures with
  unchanged data restore the prior pair; changed/incompatible data leave the service
  stopped with recovery retained for review. Existing backup files are never pruned.

**Restore Stable** is an explicit confirmed action using the retained, authenticated
previous Stable application and its matching server. It rechecks signature, hashes
and current-schema compatibility. Progress made on Beta stays current. Switching
the channel never grants downgrade permission. Missing or unverifiable Stable
recovery disables the control. Interrupted journals expose a separate confirmed
recovery action and block new updates. That action remains available when the
server is offline: local signed-app/service ownership authorizes recovery, and an
expired web session may require signing in again afterward. Recovery never disables
server authentication. Normal updates/restores require an authenticated session and
a successful signed-in GUI relaunch acknowledgement.

The older Python transaction model remains a historical test fixture; it is not
bundled or invoked by the production installer.

## Signing and hosted infrastructure requirements

Provision outside source control and chat:

- Apple Developer Program access, a Developer ID Application certificate/private
  key and its ten-character team identifier; sign helper, server, Sparkle nested
  code/framework and the application with hardened runtime and secure timestamps.
- Notary API credentials (issuer, key ID, private P8) or a protected local Keychain
  profile. Notarize, staple and assess the exact final artifact.
- Sparkle Ed25519 signing key in the local Keychain account
  `app.sumidoku.desktop.release`, or protected release-environment secret. Only the
  32-byte public key is embedded. Never rotate it silently.
- Trusted HTTPS appcast and companion catalog on the same configured host, immutable
  versioned GitHub desktop assets and protected environment approval. No host is
  silently assumed to be deployed.

Build inputs are `SUMIDOKU_RELEASE_BUILD`, `SUMIDOKU_RELEASE_VERSION`,
`SUMIDOKU_MARKETING_VERSION`, `SUMIDOKU_BUILD_NUMBER`, `SUMIDOKU_RELEASE_TEAM`,
`SUMIDOKU_UPDATE_PUBLIC_KEY`, `SUMIDOKU_UPDATE_FEED`, and
`SUMIDOKU_RELEASE_CATALOG`. `SUMIDOKU_CERTIFIED_COORDINATION` stays unset/off until
signed end-to-end qualification. The candidate workflow lists the corresponding
protected environment variables/secrets. Private signing material is ephemeral
and cleaned up; archives, checksums and public signatures are the only artifacts.

## Verification and remaining gates

Focused native security tests authenticate real ephemeral Ed25519 signatures and
exercise disposable Stable → Beta → Stable transactions, retained current progress,
failed handoff, journal recovery and incompatible schema rejection. The production
signature verifier is also exercised negatively against unsigned fixtures. Positive
bundle verification in transaction fixtures is injected explicitly and is not a
Developer ID/notarization certification.

A separate real-server smoke fixture uses original executable copies, a uniquely
named temporary LaunchAgent, an ephemeral port, generated credentials and an original
CBZ fixture. It checks preserved login/library/progress/config/packages, exactly one
listener and fixture client executable relaunches. It never controls the installed
job or copies personal data. It does not certify the real signed GUI helper handoff.

```sh
./macos/test-updates.sh
./macos/test-release-security.sh
python3 -m unittest discover -s macos/tests -p 'test_*.py'
# Build/run the PairedServerSmoke test-only driver for the real-server fixture.
```

Before publication, complete all required Rust/Clippy, frontend, native and CI gates
on the final reviewed source, then test the Developer ID/notarized Stable → Beta →
GUI/server relaunch → preserved integrity → Restore Stable → GUI/server relaunch
cycle in an isolated macOS account/VM. Include failed signature/feed, wrong identity,
malicious/corrupt archive, offline, interrupted process and failed server handoff
cases. No public release approval is requested while these gates remain blocked.

References: [Sparkle publishing and channels](https://sparkle-project.org/documentation/publishing/),
[Sparkle version/upgrading guidance](https://sparkle-project.org/documentation/upgrading/),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Current review evidence

- Complete frontend typecheck, 380 tests and production build: passed.
- Native policy assertions (including fully populated adversarial provisioning
  flags, pinned key/feed preservation and automatic-install rejection): passed.
- Native security/transaction assertions: passed, including authenticated malicious
  archives, offline/redirect rejection, Stable/Beta/Stable with newer progress,
  failed handoff, a real helper-process exit between pair mutations, tampered loose
  recovery payload, changed-data refusal and startup credential override refusal.
- Real disposable LaunchAgent/server round trip: passed with a fixture client
  relaunch probe; original login/library/progress/config/source packages retained.
- Python regressions/packaging rejection and shell/workflow syntax: passed.

The existing managed job has the expected four-argument runner contract, its runner
matches the sealed original, and the actual read-only migration version is 37.
The installed application/runtime remain untouched. Full Rust/Clippy and final-head
CI, public signing/notarization, hosted feed validation and the signed GUI helper
round trip are not certified by this review. They remain publication blockers.
