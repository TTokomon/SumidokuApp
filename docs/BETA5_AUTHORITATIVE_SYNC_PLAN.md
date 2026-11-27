# Beta 5 planning: authoritative Sumidoku hub, Aidoku transfer, and two-way synchronization

**Status:** Planning only — evidence-driven proposal, not an implementation or compatibility claim.
**Target:** Sumidoku Desktop 1.3.1-beta.5 (proposed build 14).
**Baseline:** Public 1.3.1-beta.4 (build 13), fork main at 015c323b54dbbb046559389e41d9e187a3fe9785. Stable build 9 remains unchanged.
**Research snapshots:** [Aidoku Community Sources 3d303f4](https://github.com/Aidoku-Community/sources/tree/3d303f4834adcf4a936688fa49285f3f5b293436), [Aidoku 95d1468](https://github.com/Aidoku/Aidoku/tree/95d1468d599a154f03d6a1dd06bf839d3ff3f7bd), [upstream Sumidoku 6df30aa](https://github.com/Sumidoku/Sumidoku/tree/6df30aaf221ddd7ddf937ae8be075f6a76ad59c3).

## Product contract

Sumidoku is the **authoritative record, reconciliation workspace, and outbound synchronization controller**. Aidoku remains the **primary reading application** and should automatically contribute reading events, library edits, and page/chapter state when a supported bidirectional client is available. External trackers (AniList, MyAnimeList, Bangumi, MangaBaka) are connected projections of fields they support. A user can examine, correct, add, remove, unlink, and explicitly override values in Sumidoku, then choose which approved changes to propagate.

An imported or polled external value is **not** automatically authoritative simply because it is newer. An owner-pinned correction wins until explicitly changed or unpinned. Fresh nonconflicting Aidoku reading events may be accepted automatically. A conflict that would reduce progress, resurrect a deletion, overwrite a manual correction, or misidentify a manga is held for review. Never silently propagate a deletion to external trackers.

Proposed topology: Aidoku reader <-> device bridge <-> Sumidoku sync/reconciliation hub <-> provider-specific AniList/MAL/Bangumi/MangaBaka adapters. Importing a backup bootstraps this topology; it is **not** the live synchronization protocol.

## Verified inventory: reuse instead of rewriting

### Community Sumidoku source exists in Aidoku

[Aidoku-Community/sources/sources/multi.sumidoku](https://github.com/Aidoku-Community/sources/tree/3d303f4834adcf4a936688fa49285f3f5b293436/sources/multi.sumidoku) was introduced by [community PR #846](https://github.com/Aidoku-Community/sources/pull/846), committed on 2026-11-05.

- Source metadata: ID **multi.sumidoku**, version **1**, minimum Aidoku **0.7.1**; [source.json](https://github.com/Aidoku-Community/sources/blob/3d303f4834adcf4a936688fa49285f3f5b293436/sources/multi.sumidoku/res/source.json).
- [settings.json](https://github.com/Aidoku-Community/sources/blob/3d303f4834adcf4a936688fa49285f3f5b293436/sources/multi.sumidoku/res/settings.json): configurable server base URL, optional bearer API token, or basic username/password login.
- [lib.rs](https://github.com/Aidoku-Community/sources/blob/3d303f4834adcf4a936688fa49285f3f5b293436/sources/multi.sumidoku/src/lib.rs) implements Aidoku source browsing and reading using GET /api/v1/library, GET /api/v1/manga/{id}, GET /api/v1/manga/{id}/chapters, GET /api/v1/chapter/{id}/pages and page/image requests, plus POST /api/v1/auth/login. It supports search/filter/sort, manga detail, chapters, pages, base URL, deep link and authenticated image requests.
- Its register_source! exports Source, BaseUrlProvider, DynamicFilters, BasicLoginHandler, DeepLinkHandler and ImageRequestProvider. **There is no observed write of chapter progress, library state or sync changes, no backup upload, and no tracker/PageTracker registration.** It is a reader/source connector, not proof of two-way synchronization.
- The existing source accepts credentials that effectively access the owner's server library; do not repurpose the same broad API token/password as an unattended backup or sync credential. Treat source settings as a separate security boundary.
- The source uses server-local numeric manga/chapter IDs as Aidoku keys. Document and test their stability across server/database recovery; canonical peer identity should use durable source-key + manga-key + chapter-key mapping, not assume exported numeric DB IDs survive migration.

### Aidoku native-side options and limitation

- [TrackerManager.swift](https://github.com/Aidoku/Aidoku/blob/95d1468d599a154f03d6a1dd06bf839d3ff3f7bd/Aidoku/Core/Tracking/TrackerManager.swift) registers native tracker classes directly. Its Komga, Kavita and Suwayomi integrations implement [PageTracker](https://github.com/Aidoku/Aidoku/blob/95d1468d599a154f03d6a1dd06bf839d3ff3f7bd/Aidoku/Core/Tracking/PageTracker.swift) and EnhancedTracker for page-level push/pull. This is a reusable **design pattern**, not a plugin registration feature granted to arbitrary .aix sources.
- [BackupManager.swift](https://github.com/Aidoku/Aidoku/blob/95d1468d599a154f03d6a1dd06bf839d3ff3f7bd/Aidoku/Core/Backup/BackupManager.swift) creates .aib backups locally, with automatic backup scheduling. [BackupsView.swift](https://github.com/Aidoku/Aidoku/blob/95d1468d599a154f03d6a1dd06bf839d3ff3f7bd/Aidoku/Features/Settings/Backups/BackupsView.swift) provides Export via the iOS share sheet; no native configurable Sumidoku backup receiver was confirmed.
- **A community source being installed does not imply that stock Aidoku can export all local-library mutations or accept remote library deletions through that source.** Confirm SDK capabilities and upstream maintainer position before implementation. A real automatic general-library sync client may require a narrowly scoped native Aidoku change and upstream adoption, or an explicitly distributed companion/fork. Do not promise TestFlight compatibility without live proof.

### Existing Sumidoku server/fork pieces

- [Aidoku .aib importer](https://github.com/TTokomon/SumidokuApp/blob/main/crates/server/src/api/aidoku_backup.rs): additive data mapping, dry-run/preview path, tracker associations. Beta 3-4 already improved import review and interruption recovery. Preserve it.
- [Backup API](https://github.com/TTokomon/SumidokuApp/blob/main/crates/server/src/api/backup.rs): portable JSON backup, scheduled files, safe restore contracts.
- [Sync API](https://github.com/TTokomon/SumidokuApp/blob/main/crates/server/src/api/sync.rs): cursor-based change pulling and change pushing; [change application](https://github.com/TTokomon/SumidokuApp/blob/main/crates/server/src/sync/apply.rs) has origin, sequence, revision and deletion handling. It is a **server sync primitive**, not an Aidoku client.
- [API keys](https://github.com/TTokomon/SumidokuApp/blob/main/crates/server/src/api/api_keys.rs): random secret creation, hash storage, one-time display and revocation; existing keys act with full owner identity and are **not** upload-only scoped device tokens.
- [Tracker OAuth and providers](https://github.com/TTokomon/SumidokuApp/blob/main/crates/server/src/tracker/oauth.rs), [tracker REST](https://github.com/TTokomon/SumidokuApp/blob/main/crates/server/src/api/tracker.rs), and [tracker Settings UI](https://github.com/TTokomon/SumidokuApp/blob/main/webui/src/pages/settings/TrackersPanel.tsx) already support AniList/MAL/Bangumi/MangaBaka semantics. Live native sign-in still needs registered provider apps/verified redirect handling; current token rows are documented as plaintext in SQLite and must be secured before production live credentials.
- The baseline uses schema 37. Any new migration must be forward-only, audited, and qualified against Stable restore behavior; never rewrite historical migrations.

## Field-by-field authority and reconciliation rules

| Data | Intake from Aidoku | Canonical rule in Sumidoku | Outbound destination |
| --- | --- | --- | --- |
| Title identity/source association | Source key + manga key; inspected .aib data | Exact ID first; aliases/manual matching with provenance; never auto-guess ambiguous matches | Aidoku and tracker bindings only when verified |
| Reading position | Chapter, page, completion, timestamp; offline changes | Accept nonconflicting progress; explicit user correction can rewind; page-level state remains canonical | Aidoku when bridge supports it; tracker-compatible chapter/volume only |
| Library membership | Add/remove, categories, history | Explicit removals are tombstones; missing in a backup is not a delete | Aidoku only after confirmed capability |
| Tracker status, score, start/finish date | Tracker reports | Sumidoku can override field-by-field; display individual service limitations | Supported provider fields only |
| Source/title metadata | Source updates | Preserve provenance and user-pinned overrides separately | Only when destination supports it |
| Downloads / device cache | Device-local | Never synchronize files or trigger chapter downloads implicitly | No automatic sync of chapter files |
| Credentials | None in portable backup | Local, encrypted/protected; never in sync payloads | Never exported |

A manual correction in Sumidoku increments its canonical revision, records which remote values it superseded, and queues supported outbound edits. Auto-import must not undo it. Conflicting later updates remain visible with source timestamps, received timestamps and snapshots. Do not resolve conflicts by naive highest chapter, arbitrary timestamp, or last-writer-wins alone.

## Two distinct data transport paths

### (1) Bootstrap / recovery: .aib backup transfer

Stock Aidoku can create/export .aib. In the first deliverable, use its share sheet (manual transfer or a verified user-triggered Shortcut) to a **new authenticated intake** that stores the original immutable file and applies **no changes until preview and confirmation**. Reuse the existing .aib importer and recovery workflow. Upload token must only upload/list its own receipt, not edit library, alter admin settings or call /api/v1/sync.

The mobile device cannot connect to the Mac's localhost URL. Choose an opt-in authenticated HTTPS route over a trusted network or securely paired connection. Keep default loopback private. Validate URL/origin, certificate, token scope, rate, size, content and duplicates; never put token in URL/query, backup contents, audit logs or a public cloud tunnel by default. Provide rotate/revoke, expiration, per-device status, last-success time, and explicit disconnect.

**This path is a one-way import/transfer, not true two-way synchronization.**

### (2) Ongoing two-way event synchronization

Define a versioned, authenticated **Aidoku bridge contract** around Sumidoku's existing journal. It must support:

- Stable device identity, scoped pairing credential, per-device origin, monotonic acknowledged cursor and bounded replay; no reliance on local wall clocks for conflict authority.
- Initial snapshot plus incremental upsert/remove/progress events; durable canonical identifiers; idempotent retry and no echo loops or duplicate changes.
- Local Aidoku offline queue and server change feed, including page-level read progress and library membership, with explicit deletion tombstones and resync after journal compaction.
- Sumidoku review queue: safe automatic merges, held conflicts, manual override, accept/keep/edit options, dry-run impact previews and an append-only audit record.
- Outbound provider projections executed **from Sumidoku only**. Avoid Aidoku and Sumidoku both pushing to AniList/MAL independently for the same manga during linked mode; document a controlled per-provider ownership handoff.
- Fine-grained permissions: read device-targeted changes, push own device events, upload backup; never give a mobile source token blanket admin access. Revoke one device without revoking the user's login.

**Hard feasibility gate:** confirm stock Aidoku supports all required send/receive hooks. The inspected community source does not. Before claiming full two-way sync, demonstrate a running Aidoku client that pushes a changed entry/progress while offline, reconnects, pulls an owner correction, and applies it locally without rebuilding unrelated manga sources. If stock Aidoku cannot do this, track the minimal native Aidoku implementation / upstream PR as an external dependency. The server-side half alone is not "finished sync."

## Sync Center UX

- Accounts & Integrations > Tracker Accounts: connection, login/reconnect/logout, per-service capabilities and last sync.
- Storage & Backups > Aidoku Connection: paired devices, transfer instructions, one-time upload token, received backup history, preview/confirm and disconnect.
- Library > Sync Center (or a dedicated panel): canonical value and per-provider value side-by-side, field-level Edit / Keep / Accept, pending/outbound queue, recent events, audit/revert, and explicit delete choices (remove from Sumidoku, unlink, or remove from a supported remote service).
- Show when an endpoint is read-only, unsupported, offline, expired, or awaiting review. No silent partial success.

## Execution sequence — separate PRs and hard gates

1. **P0 | Contract/feasibility research (this planning PR).** Pin community source and both upstream revisions; inspect installed .aix behavior against real published server; compare Aidoku Swift native event and tracking hooks; create capability matrix and proof of whether stock Aidoku can register a Sumidoku PageTracker or otherwise accept arbitrary remote library edits. Do not assume it can.
2. **P1 | Client strategy decision.** Choose (a) official Aidoku native upstream integration with accepted review path, (b) narrow independently maintained companion/native patch with clear distribution and licensing, or (c) limited stock Aidoku backup transfer with full sync explicitly blocked. Document dependency, API contract, permission model and support burden before merging an implementation.
3. **P2 | Secure .aib intake.** Reuse one-time key issuance concepts and existing .aib parser/dry-run. Implement narrowly scoped receiver, immutable backup receipts, review/apply UI, dedupe, rejection/retry and lifecycle. Verify a real stock-Aidoku share-sheet transfer; never silently import.
4. **P3 | Bidirectional Aidoku bridge.** Add contract tests, safe server event transport and actual Aidoku send/receive hooks. Test canonical titles from *other* Aidoku sources as well as multi.sumidoku titles. Start read-only shadow mode, then opt-in safe progress sync; only later enable user-confirmed outbound edits/deletes.
5. **P4 | Reconciliation and tracker OAuth.** Reuse existing four provider adapters; verify real authorization and permissions; protect tokens at rest; centralize provider updates in Sumidoku. Implement durable field-level override and conflict review, including score/status/date differences and unsupported fields.
6. **P5 | Beta 5 qualification.** Prove connected device, offline replay, delete/re-add, conflict correction, matching ambiguity, token revocation, old backup replay, import interruption, duplicate packets, new device pairing, journal compaction, data preservation, and no automatic chapter download. Exercise native Stable 9 -> Beta 5 -> Restore Stable 9 against disposable libraries; verify public build signing/update gates independently. No release until approved.

## Acceptance checklist (must be demonstrated, not inferred)

- [ ] Community multi.sumidoku installed and tested against public Beta 4 with safe disposable data; exact source version and Aidoku build recorded.
- [ ] Backup export from real stock Aidoku transferred to disposable Sumidoku through a documented secure path; original retained; import preview matches applied result.
- [ ] Aidoku offline chapter/page progress survives reconnect and is visible as an event in Sumidoku with reliable source ID mapping.
- [ ] A manually corrected progress value in Sumidoku propagates back into Aidoku and is not overwritten by stale offline data.
- [ ] Adding/removing a manga on one side reconciles correctly; deleting, unlinking and tracker removal are distinct, confirmed actions; no resurrection from old backups.
- [ ] Central conflict screen can edit, accept and keep chapter/score/status fields; unsupported tracker projections are shown, not fabricated.
- [ ] AniList/MAL and other configured trackers receive exactly one approved update; no two app instances fight each other.
- [ ] Tokens are per-device, least-privilege and revocable; old credentials fail; no secret disclosure via settings export/logging; no open LAN service by default.
- [ ] Schema compatibility and Beta -> Stable restore validated using disposable data; all Beta 4 functions remain intact.
- [ ] No automatic chapter downloads or silent destructive imports.
- [ ] If a stock-Aidoku feature is impossible, label the live two-way acceptance step **BLOCKED** and link the necessary native upstream work; no substitute claim based on a mock or .aib-only workflow.

## Explicit boundaries of this PR

Documentation/research only. No production code, database migrations, OAuth registrations, temporary credentials, changes to community source/Aidoku upstream, release qualifications, signing, publishing, local installation, or deployment. A separate reviewed feature PR and live client evidence are required before a Beta 5 release.

## Decisions to track

1. Whether full bidirectional sync **must work on unmodified official Aidoku/TestFlight**, or whether an upstream native change/companion distribution is acceptable. The community .aix source alone does not settle this.
2. Exact transport for Aidoku-to-Mac pairing (trusted HTTPS/LAN, private tunnel, or another supported secure path) and availability when the Mac is asleep/offline.
3. Default conflict policy: owner-pinned values and destructive changes require explicit confirmation; nonconflicting reading progress auto-merges; change this only through an explicit product decision.
4. Whether remote tracker deletion is allowed at all by default, and which external APIs support it.

## References

- [Community source and registration](https://github.com/Aidoku-Community/sources/tree/main/sources/multi.sumidoku)
- [Community source PR #846](https://github.com/Aidoku-Community/sources/pull/846)
- [Aidoku native tracking manager](https://github.com/Aidoku/Aidoku/blob/main/Aidoku/Core/Tracking/TrackerManager.swift) and [PageTracker](https://github.com/Aidoku/Aidoku/blob/main/Aidoku/Core/Tracking/PageTracker.swift)
- [Aidoku backup implementation](https://github.com/Aidoku/Aidoku/blob/main/Aidoku/Core/Backup/BackupManager.swift)
- [Existing server sync API](../crates/server/src/api/sync.rs), [apply semantics](../crates/server/src/sync/apply.rs), [Aidoku importer](../crates/server/src/api/aidoku_backup.rs), [OAuth](../crates/server/src/tracker/oauth.rs)
- [Beta 4 verified limits](BETA4_DESKTOP_REVIEW.md), [release constraints](BETA_RELEASE.md), [backup behavior](backup.md), [auth](authentication.md)
