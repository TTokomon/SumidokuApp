# Sumidoku Desktop

**A native macOS home for your self-hosted manga library, powered by [Sumidoku](https://github.com/Sumidoku/Sumidoku).**

Sumidoku Desktop is an independent macOS application project built around the open-source Sumidoku server and its existing manga-reading interface. It aims to make local setup, library management, sources, and backups feel like using a regular Mac app—without Docker or a browser tab.

> **Development status:** The native app and first-run setup are implemented in [draft PR #1](https://github.com/TTokomon/SumidokuApp/pull/1), **not yet merged into `main` or published as a signed release**. This default branch still contains the upstream Sumidoku server. Built-in Sources, live Suwayomi library connectivity and Settings → Source Lists are implemented on the draft branch; fixture and native WebKit verification are documented below. This is a community derivative, not an official Sumidoku release.

## What we're building

- **Native Mac experience:** a SwiftUI application with a dedicated window using WKWebView to show Sumidoku's existing interface.
- **Guided first run:** create a local library, choose an owner username/password, and select where its data is stored; reconnect to an existing installation without overwriting it.
- **Self-hosted by default:** one local Sumidoku server, a persistent library, native service controls, and localhost-only access by default.
- **Metadata-first library:** save manga, categories, progress, and source references; chapter downloads remain optional rather than automatic.
- **Backup and recovery:** scheduled metadata backups and an Aidoku `.aib` import flow, with explicit import previews and preservation of original backups.

## Sources

The draft application separates **Built-in Sources** from **External Sources**:

| Source | Support and status |
| --- | --- |
| **Local Files** | Setup/test/edit forms reuse upstream local folders and supported archives |
| **Komga** | Setup/test/edit forms reuse upstream OPDS catalogs |
| **Kavita** | Setup/test/edit forms reuse upstream OPDS catalogs |
| **Suwayomi** | Implemented live GraphQL saved-library browsing and reading, with public/HTTP Basic access; separate from backup import. Extension management, JWT/OIDC and remote progress sync are not implemented |
| **External Aidoku sources** | Supported by upstream through compatible repository indexes and `.aix` packages |
| **Settings → Source Lists** | Implemented GitHub/published-index discovery, naming, browse/filter, confirmed install, refresh/update and explicit subscription/package removal choices; remains in the draft PR |

Not every GitHub repository is an installable manga source. A compatible source index or package is required. An Aidoku backup may reference source IDs that must be installed before its manga and progress can be imported.

## macOS development and installation

The desktop implementation and its verified local setup are documented on the active feature branch:

- [Native macOS app, onboarding, build, and verification](https://github.com/TTokomon/SumidokuApp/blob/feat/native-macos-setup/docs/NATIVE_APP.md)
- [Local server setup, data, backups, and Aidoku import limitations](https://github.com/TTokomon/SumidokuApp/blob/feat/native-macos-setup/docs/MACOS_SETUP.md)
- [Source integration contracts, fork build/update process and tests](docs/SOURCE_INTEGRATIONS.md)
- [Draft PR #1: development progress](https://github.com/TTokomon/SumidokuApp/pull/1)

The current local build targets Apple Silicon macOS. It uses **ad-hoc code signing** for development and is **not notarized for public distribution**. There is no public downloadable macOS installer yet.

## Principles

1. **Keep ownership local.** No required external cloud account or hosted manga storage.
2. **Don't silently download chapters.** Online reading and optional offline downloads are different actions.
3. **Protect libraries.** Never overwrite an existing database or discard unmatched manga during import without clear reporting and confirmation.
4. **Build on upstream.** Reuse Sumidoku's existing reader, server, source runtime, and APIs rather than maintaining a redundant frontend.
5. **Be clear about compatibility.** Importing an Aidoku backup does not automatically sync an iPhone/iPad Aidoku installation with the server.

## Development and contributing

This repository currently carries the upstream Sumidoku source tree alongside the macOS client work in its draft branch. Changes to the core server should remain clearly separated from macOS packaging and integration features, so upstream updates can be reviewed and incorporated safely.

Issue reports and PRs are welcome. Please include reproduction steps, the macOS version, and relevant **redacted** logs; do not upload passwords, private backups, source credentials, or database files.

For the original server's features, Docker and Rust development instructions, see [the preserved upstream README](UPSTREAM.md) and [Sumidoku upstream](https://github.com/Sumidoku/Sumidoku).

## Credits and license

**Sumidoku Desktop** is built on [Sumidoku](https://github.com/Sumidoku/Sumidoku), an open-source self-hosted manga server. The original Sumidoku project and its authors retain credit for the underlying server and web interface. This project is independently maintained and is not endorsed by the upstream maintainers.

The repository's code is governed by its applicable existing licenses; see [LICENSE](LICENSE) and any bundled third-party license notices.
