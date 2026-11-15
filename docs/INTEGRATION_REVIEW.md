# Desktop integration review

Draft PRs #2 (`2980881`) and #3 (`e14aa84`) were reviewed against PR #1
(`30191f4`) and merged into the native feature lineage. Their file changes merged
cleanly; the additional safeguards below were required before runtime delivery.
The target is `feat/native-macos-setup`, not `main`. PR #1 remains draft and no
release is published by this review.

## Resolved findings

- Community bootstrap now runs for restored authenticated WebKit sessions as well
  as explicit owner creation/sign-in. Independent scheduling/network locks prevent
  duplicate requests without blocking the main thread. A private marker recognizes
  both published index aliases and preserves deliberate removal. Deferred setup
  retries at most once a minute while authenticated.
- Settings → Source Lists owns the independent catalog/package preferences, manual
  refresh and confirmed Update All actions. Failures and migration warnings identify
  exact source keys. A desktop event refreshes queries without replacing the web
  document or losing a selected import file.
- Automatic packages remain off by default. Opt-in applies only to enabled,
  installed, unreferenced sources from their original subscribed repository.
  Breaking/unknown compatibility declarations, malformed archives/WASM and
  mismatched IDs/versions are rejected or deferred to manual review.
- Download preflight is not the final safety decision. Immutable candidate files
  remain separate from active packages. The metadata write transaction rechecks
  opt-in, source version/origin/enabled state and the absence of registered manga.
  Candidate metadata inspection executes no package code; stored settings remain
  unchanged. Directory scans cannot downgrade a source from retained older bytes.
  Manual Update All excludes package-only uninstall tombstones.
- The preferences endpoint is documented in OpenAPI and generated frontend types.
  Malformed request bodies return a documented JSON error. Typed settings reads
  preserve the repository's table-ownership boundary.
- All 15 preferred Aidoku-aligned symbol identifiers resolve through AppKit on the
  current system. Runtime resolution provides native glyph fallbacks on older
  systems; no artwork or SF Symbol files are exported into the web UI. Original
  Sumidoku logo assets, red theme and real system Liquid Glass remain intact.

## Verification

| Check | Result |
| --- | --- |
| Complete Rust workspace, final source | 1,278 passed; 2 skipped |
| Strict workspace/all-target Clippy | Passed; existing vendored manifest warning retained |
| Frontend | 377 passed; TypeScript and production build passed |
| Python maintenance/symbol policy suite | 25 passed |
| Native application update/material policies | 37 assertions passed |
| Native local navigation | 12 cases passed |
| Community bootstrap fixtures | 9 assertions: offline recovery, aliases, concurrency, marker privacy, removal and manager recreation |
| AppKit symbols | 15 current-system resolutions and 2 forced older-system fallback cases passed |
| Integrated onboarding | 32 assertions each through direct-process and temporary LaunchAgent drivers |
| Integrated backup/import smoke | Source install/settings, exact-ID Aidoku import, JSON restore, categories/progress, bad-backup rejection, restart persistence and zero downloads passed |
| Embedded source forms | Sources, all four built-in setup/test forms, Source Lists and add-list form passed |
| Native windows and source preferences | Passed: native shell/material panes, separate visible WKWebView snapshots, confirmation and persisted independent preferences |

The first complete Rust run found two real integration failures: direct access to
settings from the source module, and an undocumented plain-text malformed-body
response. Both were corrected. Strict lint also caught a collapsible conditional;
it was fixed without suppressions. The final complete workspace is green.

From the committed green state, removing the write-time manga predicate produced
an actual source-version preservation assertion failure during a gated download.
Ignoring the initialization marker failed deliberate-removal persistence. Each
single-file restore returned its targeted test to green. No real library or public
network was used by these automated regressions.

Full native screenshots require an unlocked compositor. The first capture attempt
failed while the desktop was locked and was not accepted as visual evidence.
The GUI driver also now waits for a new document after reload before exercising
preference controls, preventing a click in the unloading document. Its optional
`SUMIDOKU_TEST_NO_CAPTURE=1` mode checks behavior only and explicitly reports that
visual capture was not performed.

## Installed verification

Client **1.3.0 (6)** and the integrated fork were installed through the backup-first
activator. Strict nested signature verification passed. The existing session remained
signed in after a normal server restart; quitting the app left the backend healthy.
Exactly one listener remained on `127.0.0.1:3000` and one community subscription
was present. Protected database/settings/source fingerprints, credential/config/key
files, downloads, original backups, library descriptor and pinned official binary
matched the private pre-install baseline. The new cold recovery copy is retained.
Gatekeeper assessment rejects this ad-hoc development build; no security policy was
changed. No unsigned automatic installation or automatic chapter downloads were enabled.

The current-process compositor captures native SF Symbols/materials and native
settings but omits WebKit child-process surfaces on this system. Separate native
WKWebView snapshots show the real, correctly sized embedded light/dark library,
reader and Source Lists controls. These are separate captures, not a fabricated
combined screenshot. End-to-end DOM actions and installed diagnostic status passed.

## Operation and remaining limits

- The native default is hourly catalog refresh; explicit server configuration of
  interval zero disables scheduled work. Catalog and package switches are
  independent. Refresh currently uses bounded full index requests, not conditional
  HTTP ETags. Failure retains the last valid catalog and installed packages.
- Sources with any registered manga, disabled/sideloaded sources, origin changes
  and declared breaking updates require manual handling. Fixture compatibility
  checks do not certify every live third-party source or private server.
- Default-list removal persistence lives in a private Server-directory marker.
  Retain the full private Server recovery copy when migrating; portable JSON or
  Aidoku backup documents do not carry this installation marker or private keys.
- Actual older macOS hardware, reboot/logout and elapsed backup retention remain
  manual certification steps. The build uses the available macOS 27 SDK, APIs
  introduced in 26 with runtime guards, and deployment target 13.
- Public application distribution remains blocked on Developer ID/notarization,
  signed production feed/key infrastructure and a certified coordinated Sparkle
  app/server handoff. Local ad-hoc signing does not constitute notarization.
  Unsigned automatic application installation stays hard-disabled. No source
  operation enables automatic manga chapter downloads.
- GitHub Actions evidence must be checked on the final pushed feature head; local
  results above must not be described as a passing remote CI run.

See [source handoff](SOURCE_UPDATE_HANDOFF.md), [native symbols](AIDOKU_SYMBOLS.md),
[desktop design and build process](DESKTOP_DESIGN.md), and
[native operations](NATIVE_APP.md).
