# Beta 4 — Aidoku-informed desktop design and backup connection

Reference: Aidoku/Aidoku tree 95d1468d599a154f03d6a1dd06bf839d3ff3f7bd. Studied Settings.swift, SettingsView.swift, LibrarySettings.swift, HistoryView.swift, MangaUpdatesView.swift, BrowseViewController.swift and SourceTableViewCell.swift. The upstream UI uses searchable settings, library behavior/category settings, persisted list/grid, day-based history, day-and-manga updates, and compact pinned/installed source rows with 48pt icons and 72pt rows. Adapt to macOS rather than duplicate mobile layout or copy artwork.

## Placement
- General: appearance, language, incognito, application updates.
- Library: display preferences, categories/filter groups, default category, update schedule/exclusions. Main library only search, sort, filter, grid/list, selection.
- Reader: reading behavior and display settings.
- Sources: subscribed lists, automatic source updates; main Sources page installed/pinned, discover, search and migration. Keep built-in connections.
- Storage & Backups: downloads, backup/import/restore and Aidoku file import. A recurring Aidoku backup connection depends on a verified sender protocol.
- Accounts & Integrations: security, tokens, tracker authentication and bindings.
- Server & Diagnostics: local server, cache/logs/about.

## Aidoku connection (correct direction)
Sumidoku provides the base URL and generates a dedicated revocable backup-only token; the user pastes both into Aidoku. Aidoku is the sender/client, Sumidoku is the receiving server. Do not design a form requiring an Aidoku server URL/token in Sumidoku. Confirm the exact Aidoku screen/extension and protocol before implementing a compatible receiver. Upstream BackupManager writes .aib in Documents/Backups; the public app source inspected does not establish a standard remote-backup endpoint. No direct-sync compatibility claim until verified. If the client cannot push backups natively, provide a supported sender/shortcut or shared folder rather than pretending arbitrary API credentials work. Default loopback stays private; phone access needs an explicitly enabled trusted LAN/TLS endpoint, not localhost or public exposure. Dedicated least-privilege token, hash at rest, rotation/revocation, bounded uploads, no automatic source installation, idempotent additive imports, preview/consent, backup retention and status. Never include tokens in backups/logs. Keep schema 37 where feasible.

## Follow-up acceptance
- Narrow/short macOS window: fixed logo and footer, scroll only navigation rows, no underlap, all destinations reachable.
- Native light/dark, list/grid persistence, multi-select, category/filter management via settings and deep links.
- History day grouping/search and direct resume, paginated data; updates day/manga grouping, compact operational controls and chapter detail.
- Sources: compact rows with real package icons where available, reliable cache/retry and meaningful fallback, pinned ordering, no duplicate rows or long origin URLs in main list; verify icon retrieval failures rather than masking them.
- Migration: move vs copy, complete library pagination, candidate discovery and chapter matching.
- Exercise chapter counts and transient server availability with disposable fixtures. Live tracker authorization and backup receiver compatibility require separate verification with their respective providers or clients.


## Implementation status

- Navigation uses seven Preferences destinations, with all repository actions
  in Settings → Sources. Legacy Library and Source Lists links redirect to
  their canonical panels.
- Native server checks distinguish liveness, temporary session-check failures,
  and confirmed sign-out. Aidoku import keeps the original file and recovery
  choices in memory and requires a fresh preview after failures.
- The library and chapter detail share the readable-unread criteria.
  Migration keeps originals and their history available off the shelf after
  moves and leaves failed originals shelved. No schema migration is required.
- Attached source artwork uses a validated, cached fallback from the exact
  associated repository and package version.
- The server-side tracker callback binds a single-use authorization attempt to
  its initiating account. Live desktop sign-in still needs provider registration,
  a configured HTTPS callback relay and secure native token storage. Release
  builds receive no confidential OAuth settings at compile time.
- The supported Aidoku transfer is a local `.aib` export and reviewed import.
  The Base URL and token workflow requires confirmation of the Aidoku sender
  and protocol. Storage & Backups places other import formats behind a disclosure.
