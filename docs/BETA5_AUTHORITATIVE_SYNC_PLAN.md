# Beta 5 implementation instructions — Aidoku file round trip and tracker reconciliation

**Target:** Sumidoku Desktop `1.3.1-beta.5`, proposed build 14.
**Authority:** Sumidoku is the authoritative library and reconciliation workspace; official Aidoku is the primary reader; connected AniList, MyAnimeList, Bangumi and MangaBaka accounts are remote trackers.
**Status:** Approved architecture and developer instructions. **This PR contains instructions only**, not feature code. Codex is responsible for implementation, tests, review and draft feature PRs, **not research or choosing another architecture**.
**Baseline:** `TTokomon/SumidokuApp` main `015c323b54dbbb046559389e41d9e187a3fe9785`, Beta 4 build 13; Stable build 9; SQLite schema 37.

## 1. Product workflow — locked

1. In **official Aidoku**, the user creates a `.aib` backup, selecting library, history, chapters, tracking and categories, and manually transfers it to the Mac (Files/iCloud Drive/AirDrop or another user-selected file location).
2. In **Sumidoku**, the user selects **Import Aidoku backup**, previews the exact differences, and approves an additive import. Tracker associations and chapter offsets are preserved; importing does not authenticate any provider or contact external APIs.
3. In Sumidoku's **Review & Reconcile** screen, the user sees Sumidoku's current values, the selected Aidoku backup's observations, and independently authenticated tracker states. The user can keep, correct, add or remove supported library/progress values and choose explicit tracker actions. Sumidoku remains the source of truth. No automatic cross-service writes.
4. To send approved changes back, the user creates a **fresh Aidoku backup** of the current iPhone library and selects that file in Sumidoku's **Export for Aidoku** workflow. Sumidoku patches this *complete, fresh baseline* with approved compatible changes and downloads a **new** `.aib` file. The source file is never modified.
5. The user **manually shares** that file through Files/iCloud Drive/AirDrop, opens it in official Aidoku, views its backup details, and chooses **Restore** after separately retaining a current Aidoku backup. Sumidoku never triggers restore or claims success merely because the file was sent.
6. The user can transfer a new Aidoku backup back to Sumidoku for follow-up reconciliation. This is a **manual file-based round trip**, not continuous real-time two-way sync.

**Out of scope:** Aidoku native modification, upstream contribution, Aidoku fork/companion, background sync, device pairing, listener, network tunnel, cloud server, iOS Shortcuts automation, auto-transfer or auto-restore, chapter auto-download, bulk importing an entire unlinked tracker account, and remote tracker deletes.

## 2. Immutable technical decisions and existing code to reuse

### Official Aidoku .aib format and restore behavior

The primary reference is Aidoku at `95d1468d599a154f03d6a1dd06bf839d3ff3f7bd`:
- `Aidoku/Core/Backup/Models/Backup.swift`: binary property-list encoded Codable object with optional `library`, `history`, `manga`, `chapters`, `trackItems`, `readingSessions`, `vocabulary`, `updates`, `categories`, `sources`, `sourceLists` and `settings`, plus required `date` and optional `name`, `automatic` and `version`.
- `BackupHistory.swift`: `sourceId`, `mangaId`, `chapterId`, `progress`, `total`, `completed`, `dateRead`. `BackupTrackItem.swift`: provider `trackerId`, remote track-entry `id`, `sourceId`, `mangaId`, optional title and `chapterOffset`. Those links are **not** provider credentials or live account snapshots.
- `BackupLibraryManga.swift`, `BackupManga.swift`, `BackupChapter.swift` and `BackupCategory.swift` define their full native section models. Preserve optional fields, arrays, nested Data and unknown keys from a source backup rather than reconstructing them from Sumidoku's lossy metadata model.
- `Aidoku/App/AppDelegate.swift` accepts a file URL ending in `.aib`. `BackupManager.importBackup` copies the file into the app's backup directory; **it does not apply it**. `BackupContentView` separately prompts the user to confirm **Restore**.
- `BackupManager.doRestore` **clears/replaces every included section** (e.g. `clearManga`, `clearLibrary`, `clearHistory`, `clearChapters`, `clearTracks` and `clearCategories`). It can replace source lists and offers source-install prompts. An array of only changed entries is therefore **dangerous**. A field absent from the backup may be left untouched; that is not an incremental update mechanism.
- `BackupManager.restore(from:)` returns `true` after decoding without propagating `doRestore`'s Boolean result. Therefore **do not accept the app's apparent success indication as proof of a safe restore**: post-restore state comparison is a required acceptance test.

### Sumidoku code to reuse (do not rebuild)

| Responsibility | Existing code |
| --- | --- |
| Imported `.aib` decode, dry-run, skip explanations, preview fingerprint, source retention and tracker association import | `crates/server/src/api/aidoku_backup.rs` |
| Shared additive progress and library merge | `crates/server/src/api/import_merge.rs` |
| Existing import UX, recovery and results | `webui/src/pages/settings/AidokuImportSession.tsx`, `AidokuImportWizard.tsx`, `AidokuImportReport.tsx`, `AidokuSourceRecovery.tsx` |
| Existing portable full backup (Sumidoku JSON, **not** an Aidoku file) and scheduling | `crates/server/src/api/backup.rs` and `docs/backup.md` |
| Authenticated API routing and OpenAPI contract | `crates/server/src/api/mod.rs`, `crates/server/src/api/docs.rs`, `assets/api-docs/` |
| Library edit/reader progress APIs, including explicit mark-unread | `crates/server/src/api/mod.rs` and `crates/server/src/api/reader.rs` |
| Tracker service contracts, bindings, remote state, update, current OAuth, UI | `crates/server/src/tracker/{mod,dao,oauth,sync}.rs`, `crates/server/src/api/tracker.rs`, `webui/src/api/trackers.ts`, `webui/src/pages/settings/TrackersPanel.tsx` |
| Versioned, single-value-per-key owner settings when necessary | `crates/server/src/settings.rs` |
| Tests and binary `.aib` fixture generator | `crates/server/tests/aidoku_import.rs`, `crates/server/tests/fixtures/gen_example_aib.py` |
| Desktop schema guard and rollback | `macos/App/PairedInstallation.swift`, `docs/BETA_RELEASE.md` |

Aidoku Community Sources `multi.sumidoku` at `3d303f4834adcf4a936688fa49285f3f5b293436` is a working **read-only source integration** for the Sumidoku library and reader. Do not change it or describe it as a sync bridge.

## 3. Inbound behavior and canonical corrections

- Preserve the existing default additive importer and existing data-safety semantics for legacy calls. It currently uses **maximum page progress, read-state OR, newer timestamp and existing tracker link wins**. That is correct for safe initial bootstrap but **cannot express a deliberate rewind, mark-unread or removal**.
- Add a review-oriented import path, using the existing `dryRun=true` and `previewFingerprint` mechanism. Show differences between selected backup and current Sumidoku fields (including explicit `unavailable`, `unknown`, `absent` and `zero`). Never infer a delete from an absent backup row or omitted optional section.
- **Explicit owner corrections** must use the existing authenticated local write APIs, not the additive importer. A requested rewind/unread must be retained as the accepted Sumidoku value, not automatically overwritten by later older snapshots. Prevent stale preview acceptance with a canonical revision/fingerprint check.
- Retain imported tracker links (provider, per-account identity after independent login, remote entry ID, manga/source IDs, title, offset, chapter-vs-volume mode) and the inactive archive for unsupported services such as Shikimori. A provider/media match based on title alone is **not** sufficient to approve a write.
- Imported snapshot comparison is **user-triggered**, not a background job. The selected upload may be held only in the current authenticated UI session; do not retain original uploaded backups on the server by default. Do not ingest Aidoku's source credentials, UserDefaults secrets or settings into live runtime configuration.
- Library actions must distinguish **remove from Sumidoku**, **remove from the next Aidoku export**, **unlink tracker**, and **remote provider deletion**. The last action is disabled in Beta 5.

## 4. Reverse Aidoku export: mandatory algorithm

**Use a user-selected fresh official Aidoku `.aib` as a complete baseline; do not create a whole Aidoku backup from only Sumidoku database rows.**

Implement the feature as a dedicated authenticated endpoint and UI (suggested server file `crates/server/src/api/aidoku_export.rs`; suggested UI component `webui/src/pages/settings/AidokuExportWizard.tsx`).

### Encoder and data handling

1. The user selects a recent, complete source backup from **their actual Aidoku app**, with library, history, chapters, categories and tracking sections included. Validate that the required sections exist and are complete for the proposed operations; if not, block export with a precise message. Do not claim a timestamp alone proves freshness.
2. Parse it into a bounded generic binary-plist tree (`plist::Value` or equivalent) to preserve unknown and optional fields, collection membership and Swift-compatible dates/Data. Produce a new binary plist with extension `.aib`. Never modify the original file.
3. Match each intended correction by **exact** `(sourceId, mangaId, chapterId)` for history/chapters and `(sourceId, mangaId, trackerId, remote track ID)` for tracker links. Account/edition ambiguity, missing sources, changed identifiers or missing baseline records block that correction; no fuzzy auto-writes.
4. Construct a **complete output array for every section being replaced**: preserve all unrelated elements and unknown fields from the fresh baseline. Apply only the approved individual changes (including unsupported/no-op explanation). A partial array, especially `history`/`library`/`trackItems`, must never be used as a patch.
5. For progress changes, preserve all other `history` rows and associated `chapters`. Handle `completed`, `progress`, `total` and read date consistently; an explicit mark-unread may require removal of the corresponding history row rather than merely toggling `completed`. If sessions or other dependent records would be invalidated, show impact and block or require an explicit supported decision; do not fabricate read sessions or dates.
6. For library additions/removals or category updates, emit **complete** consistent `library`/`manga`/`categories` arrays only when the exact Aidoku source identity and all required metadata/relations are valid. An unrepresentable new title, unavailable source, or ambiguous chapter mapping is a **per-item refusal**, not a reason to delete unrelated items.
7. Preserve the baseline's unaffected `readingSessions`, `updates` and `vocabulary` when present. Omit `sources`, `sourceLists` and `settings` from the **generated** backup by default so it does not restore credentials, overwrite device settings, replace source lists or prompt for implicit installs. Include only a narrow nonsecret settings subset if a separately validated operation truly requires it. Never include Sumidoku OAuth tokens, HTTP sessions, passwords or API keys.
8. Present a **pre-export dry-run report**: baseline age/section counts, incoming canonical changes, withheld/unsupported operations, projected output counts and warnings. Bind the final click to the baseline digest + current Sumidoku values/version + selected corrections so a stale preview cannot export newer or mismatched contents.
9. Return an attachment suitable for the browser's normal **Save/Share** workflow, with no automatic iCloud write, iPhone connection, backup restore or upload service. Include clear human instructions: **first create and keep a separate current Aidoku backup**, then manually import the new file, inspect it in Aidoku and explicitly select Restore.

**Fail closed:** If full-array preservation, dependency safety, per-field fidelity or binary-plist decode/encode cannot be proved, do **not** enable the corresponding export operation. No pretend-success UI. Use one-way Aidoku -> Sumidoku import for unsupported edits.

## 5. Tracker reconciliation and OAuth — concrete behavior

- For imported Aidoku `trackItems`, map known IDs `anilist`, `myanimelist`, `bangumi` and `mangabaka` through the existing provider adapters. Preserve unsupported IDs as inert, visible associations. Treat imported `id` as a remote entry ID: never assume it is interchangeable with the provider's media catalog ID or evidence of ownership.
- Authenticate each provider independently; use its existing `get_state` to fetch live state only for explicitly linked/matched manga. **Full remote account-library discovery is out of Beta 5.** Show service, account identity, observation time, chapter/volume, reading status, score and supported dates with their units and null/unsupported distinctions.
- Show **Sumidoku canonical** / **Aidoku backup observation** / **tracker API observation** side by side. User actions: `Keep Sumidoku`, `Accept observation`, `Edit canonical`, `Unlink`, `Preview provider update`, `Confirm provider update`. An imported backup, an OAuth login, or an ordinary UI page refresh **never** triggers a tracker mutation.
- Existing automatic tracker writes live in `crates/server/src/tracker/sync.rs` and `reader.rs:notify_tracker_read`. For Beta 5 managed bindings, **turn off or fence automatic writes before enabling review-controlled operations**, including indirect pushes caused by pulling provider progress. Do not allow existing and new workers to race. Clearly tell the user to disable conflicting direct Aidoku tracker auto-update where applicable; stock Aidoku cannot be controlled by Sumidoku.
- Use read-before-preview, explicit user confirmation, recheck-current-bindings before send and provider read-back after update. Unknown outcomes (timeouts after sent write, rate limits, expired tokens, unexpected status/score conversions) are **not successful** and must not be replayed blindly. No remote deletions or silent list-entry creation. If a provider cannot support a requested field accurately, show it as unsupported.
- Preserve the current native OAuth flow structure but **do not use plaintext legacy OAuth rows for newly connected production accounts**. Protect new tokens with a reviewed macOS Keychain-backed strategy or encryption with a Keychain-protected key; guard callback state, account identity, expiry and one-time consumption. The current release contains no provider registrations; **mock provider API calls for tests** and keep live connect/mutate controls disabled until separate explicit provider credentials and test accounts are approved.
- AniList's published authentication flow does not provide refresh tokens; require reauthorization when needed. MAL uses a different PKCE method (`plain` in its documented/current flow), so do not replace provider-specific behavior with a universal S256 requirement. Existing adapters are reused and provider-specific behavior must remain explicit.

## 6. Database, packaging and security constraints

- **Schema 37 only for these initial Beta 5 implementation PRs.** The existing paired updater rejects different live/catalog schema and Restore Stable requires compatibility. Do not edit historical migrations or add schema 38 under this approval.
- For a manual file workflow, use existing library/progress/tracker tables and authenticated calls; keep transient comparisons in UI session memory. If small durable owner overrides are required, use existing strictly validated, versioned, **nonsecret**, bounded owner settings and commit affected local data in one existing SQLite transaction. No fragile sidecar claiming cross-database atomicity. If an essential operation cannot be made durable safely on schema 37, leave that operation disabled and report a specific migration/updater proposal **without implementing it**.
- The app must stay loopback-only. No new listeners, reverse proxies, relay deployments, third-party analytics or permissions. Upload/download endpoints require existing session authentication, CSRF/origin protections, body/decoded-object limits, bounded parsing and no user-controlled filesystem writes. No sensitive source data in logs or committed fixture files.
- Follow `AGENTS.md`, `LESSONS.md`, `docs/code-standards.md` and `docs/architecture.md`. Update `docs/backup.md`, OpenAPI contracts, generated client types and localized UI copy for implemented routes. Retain original import UX, native app updates, Stable Restore, user sessions, source settings and installed manga.
- No automatic chapter downloads and no silent source installation.

## 7. Implementation sequence — Codex writes code, not research

Each feature milestone uses a **separate implementation branch and draft PR** against `main`, references planning PR #17, includes focused red/green regression tests and an independent code/security review, and remains unmerged/unpublished until separately approved.

| Milestone | Implement | Acceptance gate |
| --- | --- | --- |
| **I1 — inbound file review hardening** | Extend existing Aidoku wizard and importer to present per-field differences and explicitly supported manual corrections; preserve original additive import defaults and tracker association handling. | Imported library, categories, history, page progress, offsets, chapter mode and unsupported tracker archive survive; preview fingerprint stops stale applies; old imports do not undo an explicit rewind or unread; corrupted/missing-source files fail safely. |
| **I2 — reverse Aidoku file writer** | Add baseline-patch binary `.aib` exporter, preview/fingerprint, user-selected fresh file and Save/Share UI. Start with progress/completion corrections; enable membership/category/tracker-link edits only after their complete-array and reference tests pass. | Full backup field preservation; unrelated records unchanged; explicit rewind, unread and page-zero semantics; sensitive settings omitted; unknown keys intact; corrupt/partial source blocked; binary plist decode succeeds and round-trip fixture matches expected Aidoku data. |
| **I3 — reconciliation workspace** | Add a concise side-by-side canonical/Aidoku/tracker view under the existing Library or Accounts & Integrations navigation, reusing current tracker and import components. Manual approve/edit/keep and clear source provenance. | No accidental provider writes, no destructive restore, unsupported fields visibly disabled, stale canonical/backup versions rejected, imported links not falsely shown as authenticated accounts. |
| **I4 — controlled provider connectivity** | Secure token storage, reconnect/expiry handling, read-only provider state and single-writer gate; enable tested manual writes per provider only after approved registration. | Mocked adapter tests for all four providers, authentic account proof and read-back before enabling any live provider, no infinite push loops, unknown outcomes held, provider-specific lossy fields warned, remote deletion disabled. |
| **I5 — Beta 5 acceptance and qualification** | Full regression/security review and disposable Stable 9 -> Beta 5 -> Restore Stable 9 qualification; verify exported `.aib` on a disposable **official Aidoku** install with fresh real backup and post-restore re-export. | No loss of unrelated titles, progress, categories, trackers or reading sessions; update compatibility, no chapter downloads, no exposed secret, no automatic file transfers; publication requires separate approval. |

**Physical-client gate:** Unit/fixture simulation is not proof that official Aidoku restored the artifact correctly. If Codex does not have a disposable official Aidoku installation, it must supply the exact manual test procedure/artifact for the owner and mark I5's live restore step **UNVERIFIED**; never touch the owner's real library or claim live support based solely on file parsing.

**Stop/continue rule:** Codex should begin **I1 implementation immediately**, then move through independent feasible work. An external OAuth registration, a schema migration, or lack of an iOS test client blocks only that dependent feature, **not** the rest of the Beta 5 implementation. Codex must not substitute another research report for code.

## 8. Completion report format

For each implementation PR: exact diff/commit; reused code; completed features; test commands and outcomes; remaining blocked features with reasons; UI screenshots when relevant; live official Aidoku proof status; schema-37/Stable update safety; and whether the milestone is ready for review. Do not merge, sign, install, qualify a release, publish or promote Stable without separate instruction.

**PR #17 is the developer instruction source, not an implementation branch.**