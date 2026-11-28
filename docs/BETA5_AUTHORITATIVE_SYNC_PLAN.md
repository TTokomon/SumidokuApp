# Beta 5 — implementation contract (reuse-first, no research phase)

**Target:** Sumidoku Desktop `1.3.1-beta.5` (build 14). **Base:** `TTokomon/SumidokuApp` `main@015c323b54dbbb046559389e41d9e187a3fe9785`, Stable build 9, Beta 4 build 13, database schema **37**.
**Instructions PR:** #17 is documentation only. **Codex implements features in separate draft PRs**; this is not a request to investigate architecture, redesign UX, modify upstream repos, or produce more plans.

## 1. Product contract — settled

**Sumidoku is the authoritative library and reconciliation hub. Official Aidoku remains the primary reader.** File exchange is **manual**, through .aib and Files/iCloud Drive/AirDrop; no continuous two-way device sync.

- **Aidoku → Sumidoku:** user exports a .aib, imports with the *existing* preview wizard; preserve library, categories, chapter/page progress, history and provider associations/offsets. Imported tracker links are **not** authenticated provider sessions or full remote account records.
- **Sumidoku ↔ AniList/MAL/Bangumi/MangaBaka:** connect the user's **same actual account** with Sumidoku's existing provider OAuth; verify identity and title/entry bindings, read live remote chapter/volume, score, status and supported dates; show differences and apply only **explicitly approved** changes. These APIs do **not** provide Aidoku's per-page history.
- **Sumidoku → Aidoku:** produce a new Aidoku-compatible **binary-plist .aib from Sumidoku's complete, verified canonical records**. It may intentionally replace included Aidoku library, chapters, history, categories and tracker links, including owner-approved rewinds, deletions and unlinks. **No fresh Aidoku backup is needed as exporter input.** User manually shares the file, imports it in official Aidoku, then explicitly confirms **Restore**. Instruct user to keep a separate fresh Aidoku recovery backup beforehand because newer iPhone activity not yet imported might be overwritten.
- **Completeness rule:** never mistake a skipped source, ambiguous mapping, failed import or unsupported field for the owner's intentional deletion. Include a backup section only when its **entire replacement array and all required relationships are verified**; omit or block unsupported sections. An **empty array clears** an Aidoku section. Omitted optional sections may stay unchanged.
- No auto-upload, auto-restore, source package installation, chapter download, native Aidoku modifications, community-source changes, new listener/cloud relay, remote tracker deletion, or silent provider API writes.

## 2. Audited reuse map — mandatory before adding code

Our fork **already implements the following**. Extend the smallest appropriate existing unit; do not add a second architecture:

| Requirement | Reuse **in our fork** | Only missing work |
| --- | --- | --- |
| Aidoku .aib decode, source retention, tracker IDs/offsets, dry-run and fingerprint | `crates/server/src/api/aidoku_backup.rs`, `api/import_merge.rs`; `tests/aidoku_import.rs` + `fixtures/gen_example_aib.py` | Side-by-side canonical-vs-import observation and explicit owner correction path; **do not rewrite the importer** |
| Full Sumidoku state snapshot | `api/backup.rs:build_backup_doc`, existing SQLite store queries | Small Aidoku output projection; **all chapter metadata** query needed because `BackupDoc.progress` only covers chapters with nondefault progress |
| Progress editing incl. rewind/mark-unread | `api/reader.rs:ProgressPatch` and existing authenticated patch routes | Review-specific orchestration; default additive import currently takes max(page) / OR(read) and **cannot** express rewind |
| Library/category management | Existing library and category APIs; `webui/src/pages/library/LibraryManagement.tsx` | Reuse existing edit operations; don't build another CRUD service |
| Aidoku file wizard and backup UI | `webui/src/pages/settings/SettingsSections.tsx` (`BackupSection`), `AidokuImportSession.tsx`, `AidokuImportReport.tsx`, `AidokuSourceRecovery.tsx`, `AidokuImportWizard.tsx` | Extend the same Settings > Storage & Backups workflow; add only minimal Export for Aidoku UI |
| Tracker connections, link editor, remote state, score/status/progress forms, chapter offset | `webui/src/pages/settings/TrackersPanel.tsx`, `webui/src/components/trackers/TrackerSection.tsx:TrackerEditForm`, `webui/src/api/trackers.ts` | Compose a compact reconciliation view around **existing** controls. Do not create another tracker dashboard/editor/search form |
| Four provider adapters and chapter/volume conversion | `crates/server/src/tracker/providers/{anilist,mal,bangumi,mangabaka}.rs`, `tracker/core.rs`, `tracker/mod.rs`, `api/tracker.rs` | Approved read/compare/write gating, secure credential storage and account verification; **do not replace adapters or core math** |
| Existing tracker auto-push and pull | `tracker/sync.rs`, `api/reader.rs:notify_tracker_read`, `api/tracker.rs:sync_tracker_link` | Fence existing auto-push for review-managed bindings; **do not add a competing background worker** |
| Auth, config, routing, docs and tests | `api/mod.rs`, `api/docs.rs`, `settings.rs`, existing query/client/type modules | Reuse session auth/CSRF, existing JSON owner settings if safe, and test fixtures |
| Desktop update/rollback | `macos/App/PairedInstallation.swift`, `docs/BETA_RELEASE.md` | Prove schema 37 and Stable 9 restore unchanged; no migration |

**Verified upstream comparison:** `Sumidoku/Sumidoku@6df30aaf221ddd7ddf937ae8be075f6a76ad59c3` and our fork have **identical Git blob SHAs** for `tracker/core.rs`, all four tracker-provider implementation files, `tracker/mod.rs`, `tracker/sync.rs`, `api/sync.rs` and `webui/src/api/trackers.ts`. Their implementations are **already here**. Our `aidoku_backup.rs`, `backup.rs`, `tracker/oauth.rs` and other integration files **differ** because the fork has local behavior; never wholesale-overwrite them with upstream. Reuse or adapt only a concrete, compatible upstream patch if required; no upstream porting project.

**Aidoku reference, not code to paste:** `Aidoku/Aidoku@95d1468d599a154f03d6a1dd06bf839d3ff3f7bd` has `Core/Backup/Models/Backup*.swift`, `Core/Backup/BackupManager.swift`, `Features/Settings/Backups/BackupContentView.swift` and `App/AppDelegate.swift`. Use these to implement **interoperable wire fields and restore semantics**. Aidoku is GPL-3.0; **do not copy its Swift implementation or assets into our MIT codebase** without explicit license review. `Aidoku-Community/sources@3d303f4834adcf4a936688fa49285f3f5b293436` `sources/multi.sumidoku` already browses/reads our server; it is **not a write/sync extension** and needs no changes.

### Exact Aidoku format/restore contract

- Aidoku's `Backup` has optional `manga`, `library`, `history`, `chapters`, `trackItems`, `categories`, `readingSessions`, `updates`, `vocabulary`, `sources`, `sourceLists`, `settings`; required `date`. Swift binary plist dates/data and optional fields must round-trip correctly.
- `BackupHistory`: `sourceId/mangaId/chapterId/progress/total/completed/dateRead`. `BackupTrackItem`: `id` (remote tracking entry), `trackerId` (provider), `sourceId/mangaId/title/chapterOffset`. Do not mix catalog media ID, list-entry ID and Sumidoku local numeric DB ID.
- `BackupManager.importBackup` only *copies* the .aib file to Aidoku's Backups directory. `BackupContentView` asks the user to confirm **Restore**. Restore clears and rebuilds every **included** section; `[]` is **not** equivalent to absent/null. Aidoku can write empty arrays even for unchecked backup options; presence in a user-provided backup does not imply its data is comprehensive.
- Aidoku restore can process source-list/settings sections and prompt to install missing sources. Our generated file **omits these sections by default**, to avoid credential/settings changes or unintended installs.
- Aidoku's `restore(from:)` returns true after decode without propagating `doRestore`'s result; a success toast or decodable plist alone **does not** prove a complete restore. Use post-restore re-export comparison on a disposable official installation.

## 3. Minimal architecture (avoid overengineering)

```text
Aidoku .aib file -> existing authenticated importer/preview -> canonical SQLite
                                                       |
Tracker adapters -> existing live state APIs -> compact review UI -> explicit owner edits
                                                       |
Canonical SQLite -- read-only snapshot / verified projection --> .aib encoder --> manual Share
```

Keep **one source of truth** (existing DB), **one import pipeline** (existing importer), **one tracker-provider registry** and **one existing settings/navigation structure**. Only genuinely new domain capability is a **canonical-to-Aidoku projection/encoder with completeness checks**, plus thin reconciliation composition.

No new event bus, background sync journal, device API, synchronization daemon, cache index, full new design system, duplicate repository/service layer, second auth flow, separate standalone dashboard, third-party file-transfer service or generalized framework.

**Prefer pure functions for** `canonical snapshot -> Aidoku sections`, `snapshot/remote observations -> field differences`, and `selected edits -> preview`. Keep database/HTTP operations as thin existing adapters. Stable source identity is the tuple `(sourceKey, mangaKey, chapterKey)`, with exact provider + authenticated account + remote entry identity; never use title similarity as authorization.

## 4. Canonical export rules (one scoped new writer)

Implement an authenticated `Export for Aidoku` path (only if new code genuinely required; suggested `api/aidoku_export.rs`) using **existing `backup.rs` snapshot/read routines and the existing `plist` dependency**. Avoid a new serialization framework or independent mirror database.

| Aidoku section | Source of canonical truth | Required handling |
| --- | --- | --- |
| `manga`, `library`, `categories` | Existing manga/member/category tables | Complete verified arrays incl. intentional removals, exact source IDs and matching category membership; map metadata fields faithfully |
| `chapters` | All relevant chapter rows, **not only** `BackupDoc.progress` | Full stable chapter keys, chapter/volume, source order, referenced metadata; no orphan relations |
| `history` | Existing chapter_user page, read flag, timestamp and owner corrections | Complete covered reading history, explicit lower progress, page zero, unread/removed history; no invented read sessions or dates |
| `trackItems` | Verified tracker_link and associated imported offsets | Correct Aidoku provider IDs, exact remote track ID, chapter offset, source/manga; intentional unlink removes entry in export only, **not** on remote API |
| `readingSessions`, `updates`, `vocabulary` | Not fully represented in Sumidoku's portable backup | Omit unless fully and safely modeled/preserved; check that omitted dependent sessions are not left with invalid references after a history replacement |
| `sources`, `sourceLists`, `settings` | Device-specific Aidoku data, not equivalent to Sumidoku settings | Omit. No credential transfer or source installation |

A section is emitted **only** with complete canonical coverage and validated dependencies. Before download, show counts, included/omitted sections, changed/removed records, provider bindings and the date of last imported Aidoku snapshot; warn newer Aidoku activity may be replaced. Bind export to a canonical snapshot/digest so changes after preview invalidate it. If completeness cannot be proved, **block that section or export**; never silently drop unknown/unmapped manga.

Encode a new complete binary .aib with `date`, clear descriptive `name`, correct native Codable field names and `.aib` download. **A newly exported Aidoku backup is not an input requirement**. Show user how to make a separate recovery copy on iPhone before restoring.

Avoid treating tracker `get_state` as page history. If the user is logged into the same AniList/MAL account, Sumidoku can read current status/score/chapters/volumes for **correctly verified bound entries**; the binding in .aib alone does not establish the account or prove current remote state.

## 5. Review, corrections and remote operations

- Extend existing Import Aidoku wizard with a concise **differences** view; reuse `dryRun=true` and `previewFingerprint`, and retain the legacy additive defaults for existing callers. Imported older progress must not undo a later **explicit manual rewind/unread**; apply these through `reader.rs:ProgressPatch`, not `import_merge.rs`'s max/OR logic. Absence from a partial backup is not deletion.
- Reuse `TrackerSection.tsx:TrackerEditForm`, `TrackersPanel.tsx`, and `api/trackers.ts` for search, binding, offset, score/status/chapter and OAuth controls. **Critical existing behavior:** `TrackerEditForm.save` currently calls `updateTracker` directly, and its pull-sync can subsequently push to **other** trackers; do not mount these mutable actions unchanged in an allegedly read-only reconciliation view. Factor a small shared presentational editor/preview and add explicit confirmation/preflight gating to existing mutation paths. Prefer one adapter and one editor, not a second form.
- Treat Sumidoku canonical / Aidoku latest file snapshot / each authenticated provider live state as distinct timestamped observations. Different editions, chapter units or account identities are held for review. Provide **Keep**, **Accept**, **Edit**, **Preview provider write**, **Confirm write**, **Unlink**; distinguish library removal, Aidoku export omission, remote unlink and remote delete. Remote deletes are **disabled** in Beta 5.
- `tracker/sync.rs` auto-pushes on read events, while `api/tracker.rs:sync_tracker_link` can push to other bindings. For new *review-managed* bindings, **fence automatic and indirect writes** before offering explicit approval. Do not silently change unrelated legacy user behavior or create a second tracker worker. Warn about Aidoku's own auto-updates to the same accounts.
- On approved provider write, validate same account + exact binding + canonical revision + last remote state, then send with the existing adapter and read back to confirm. Timeout after write / rate limit / auth expiry is **unknown, not success**; no blind duplicate writes. No automatic remote creation/deletion or unsupported field conversion.
- OAuth is currently implemented but `tracker_oauth_token` in migration 0027 stores plaintext tokens. No production credential connection until reviewed Keychain-backed encryption/reconnect/rollback handling, exact registered redirects and separately authorized provider apps. Test providers with local stubs now; live credentials/writes require user approval. Reuse the existing four OAuth/provider implementations, **never a second OAuth system**.

## 6. Implementation stages — short, separately reviewable PRs

| Stage | Implement only the missing delta | Mandatory proof |
| --- | --- | --- |
| **I1 — import + correction integration** | Reuse the existing import wizard, report and merge code; add minimal canonical comparison/owner correction workflow without replacing existing UI | Existing import unaffected; offset/archive preserved; stale preview denied; explicit rewind/unread not undone by stale import; corrupted/partial backup safely rejected |
| **I2 — canonical .aib export** | New narrow binary-plist projection/encoder and **Export for Aidoku** action in the existing Backup section; initial sections enabled only when complete | Reparse with Aidoku model fixture; stable IDs and section completeness; intended deletions/rewinds; no unexpected clearing of other sections; no sensitive data |
| **I3 — reconciliation UX** | Compose existing trackers editor/account/remote-state controls and imported snapshot report into a compact, consistent page or panel | No duplicate UI/service; read-only mode makes zero writes; explicit approved actions only; ambiguous entry disabled; provenance/units shown |
| **I4 — secure provider actions** | Protect OAuth tokens; fence old auto writes for managed bindings; implement confirm/read-back within existing API and adapter stack | Stubs for all four providers; account verification, rate-limit/timeout, concurrent update, approval stale/revoked, no feedback loop; live test requires approved accounts |
| **I5 — Beta qualification** | Full tests/review and disposable Stable 9 -> Beta 5 -> Restore Stable 9; test generated backup on disposable **official Aidoku** | Real Restore then new Aidoku export compared field by field; canonical records and deliberate deletes correct; unsupported device-local fields preserved; no chapter auto-download, network exposure or credential leak |

**Live-client test gate:** If no disposable official Aidoku device is accessible, Codex supplies exact manual acceptance steps and marks reverse-export restore **UNVERIFIED**. Do not touch the owner's real Aidoku library or claim that decoding the file proves restore compatibility.

## 7. Engineering protocol to optimize Codex tokens and product quality

1. **One-time context, not repeated repository research.** Read this document + `AGENTS.md`, `LESSONS.md`, `docs/code-standards.md`, `docs/architecture.md`, and only the named files relevant to the **current stage**. The reuse/format questions above are settled. No general web search, exhaustive repository audit, upstream comparison, or long alternate architecture report unless a **new failing test proves the stated contract wrong**. Report a concrete mismatch, don't silently improvise.
2. **Use a reuse-before-create gate.** Before adding a module, endpoint, component, state store or dependency: identify its closest existing counterpart, state exactly what behavior is absent, and extend/extract existing code where reasonable. A new module is acceptable for the genuinely missing .aib encoder; duplicated OAuth services/import pipelines/trackers are not.
3. **Small vertical slices and bounded diffs.** One feature-stage branch/PR, normal review against main, focused independent tests first. Keep DB/API/UX edits connected to the same user-visible behavior. Avoid opportunistic renames, whole-app redesigns, dependencies, schema changes, broad refactors or speculative support for future automation.
4. **Test efficiently but fully.** First write a focused regression that fails for the missing behavior, then implement and rerun. Reuse existing binary .aib fixtures and fake HTTP providers; use disposable SQLite and local mocks, **never live networks or real local library in automated tests**. Before submitting each PR run the required **full** Rust nextest workspace, strict clippy, and web check/test/build when those layers changed, plus the relevant native and security checks. Follow the repository's break-and-restore rules; do not skip mandatory gates to save tokens.
5. **Be economical with context, not safety.** Do not print full source files, gigantic test logs, repeated specifications or duplicate reports. Capture error excerpts with file:line, exact failing test, minimal diff and verdict. Stop repeated speculation after one concrete blocker; continue independent work. A compact PR report should say **reused → added → tested → blocked → approval needed**, with commits and screenshots when useful.
6. **Protect release boundaries.** Schema stays **37**; no historical migration edits; don't change `Cargo.toml` version or trigger release workflows. Don't merge, install, sign, deploy, tag, publish or modify upstream/community sources without separate approval. Maintain an explicit feature gate for any capability not proven safe; do not replace a real test with a mock-success claim.

**Stop/continue rule:** Begin **I1 code implementation** on a new draft PR; then work through feasible independent stages. OAuth registration or device access blocks only live acceptance, not offline work. PR #17 remains the reference instruction document and **must not accumulate implementation code**.

## 8. End-of-stage report

**PR / commit:** exact reference. **Reused:** file names and logic. **Added:** only missing behavior. **Tests:** focused and mandatory full-suite outcomes. **Safety:** schema, Stable rollback, credential and Aidoku loss-prevention gates. **Blocked:** external proof with precise reason. **Next:** approved independent stage. No merge or release on your own.