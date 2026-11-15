# Native macOS setup

This fork adds installation and service helpers under `macos/`. It runs the official Sumidoku binary and its embedded web interface. No Docker, custom frontend, Rust compilation, or additional permanent service is required.

## Open Sumidoku

Open **Sumidoku.app** from Applications or the Dock. The genuine SwiftUI/WKWebView desktop client uses the existing server and interface, with native status/start/restart controls. See [native application instructions and verification](NATIVE_APP.md).

Sign in as **admin** with the existing password in the private local file. The app does not read or reveal it:

```sh
open -e "$HOME/Library/Application Support/Sumidoku/config.toml"
```

Do not paste this file into GitHub, chat, or shell commands. The configured password is reapplied on server boot, so a change only in the web UI would be reset at the next restart. The server also remains accessible at **http://localhost:3000** when a browser is deliberately desired; Safari is not required to use the desktop app.

The LaunchAgent starts independently at macOS login. Quitting the desktop client does not stop the server or backups. A real logout/login auto-start cycle has not been observed here.

## Installed locations

- Application state, database, source packages, cover cache, private configuration: `~/Library/Application Support/Sumidoku/`.
- Executable and signal-forwarding runner: that directory's `bin/`.
- Optional chapter downloads: that directory's separate `downloads/` child. Nothing is downloaded automatically.
- Scheduled JSON backups: `~/Documents/Sumidoku Backups/`, separate from the application data root.
- Protected, manually validated snapshots: `~/Documents/Sumidoku Backups/checkpoints/`.
- Logs: `~/Library/Logs/Sumidoku/server.log` and `server-error.log`.
- User LaunchAgent: `~/Library/LaunchAgents/app.sumidoku.server.plist`.

Runtime files and credentials are outside the Git checkout. Updating or moving the checkout does not relocate the database. Sumidoku pins `sources/` and `page-blobs/` beneath its config root; those paths cannot be independently configured. `downloads_dir` and the backup destination are supported configuration options. A reader may fetch/cache pages when deliberately opened; “no automatic downloads” is not an offline-only network policy.

## Install on another Apple Silicon Mac

From this repository, with Python 3.11+ available:

```sh
python3 macos/install.py
./macos/service.sh start
python3 macos/configure.py
```

The installer is pinned to official release **v1.23.3**, published 2026-11-14. It downloads `sumidoku_1.23.3_aarch64-apple-darwin.tar.gz` and checks SHA-256:

```text
c6fcd267ab03cc456199fbc556ed1b7b8b49c41f8c0858f63e90b7eeb05318a1
```

This matches the digest published in GitHub's [official release API](https://api.github.com/repos/Sumidoku/Sumidoku/releases/tags/v1.23.3). The installer refuses to replace an existing binary, config, or LaunchAgent; use the backup-first update procedure below. No `sudo` is required. A checksum checks the downloaded artifact against GitHub's release metadata; it is not Apple notarization.

If Gatekeeper blocks an official download, first verify the release URL and checksum. After the blocked launch, open **System Settings → Privacy & Security → Open Anyway** for that specific executable and complete macOS's confirmation yourself. Then start the service again. Do not disable Gatekeeper or clear quarantine globally. See [Apple's app approval instructions](https://support.apple.com/en-us/102445). No Gatekeeper exception was needed during this installation.

## Start, stop, restart, and disable

Run these from the checkout:

```sh
./macos/service.sh status
./macos/service.sh stop
./macos/service.sh start
./macos/service.sh restart
./macos/service.sh open
./macos/service.sh disable
./macos/service.sh enable
```

`open` launches the installed native application. Build/install it using [the native app instructions](NATIVE_APP.md) first. It does not open a browser or control the backend.

`stop` unloads the job for the current login; the plist remains for the next login. `disable` additionally disables its launchd label across logins. `enable` reverses that and starts it. Repeated `start` calls reuse the loaded job. Start waits for the health endpoint. Restart gracefully signals the retained LaunchAgent and waits for a new healthy runner; stop waits for the previous runner to exit. Do not launch a second server manually on the same data directory.

The runner forwards termination to the server as **SIGINT**, which the shipped server handles for graceful shutdown. `KeepAlive` restarts an unexpected exit; `ThrottleInterval` limits restart loops. The job runs in the current user's GUI launchd domain and uses no root daemon. Inspect logs with:

```sh
tail -n 80 "$HOME/Library/Logs/Sumidoku/server.log"
tail -n 80 "$HOME/Library/Logs/Sumidoku/server-error.log"
lsof -nP -iTCP:3000 -sTCP:LISTEN
```

The listener must show **127.0.0.1:3000**, not `*:3000`. If the port is occupied by another app, stop and identify it rather than killing an unrelated process. Logs are persistent; review their size periodically and archive them with the service stopped if needed. This setup does not add another log-rotation daemon.

## Metadata-only operation and local security

The private configuration binds loopback explicitly; upstream's non-Windows default would otherwise listen on all interfaces. A random admin password is configured, and anonymous library API requests are rejected. No firewall, router, domain, public tunnel, cloud provider, or optional trawl sidecar is configured.

`configure.py` explicitly stores and reads back:

- Automatic download of new chapters: **off**.
- Automatic-download candidate limit: **0**.
- Reader-ahead download: **off**.
- Scheduled library update interval: **0/off**.

The config file also supplies safe defaults. Runtime settings can override download defaults; an imported JSON settings section could re-enable them. For future restores, deselect **settings**, or rerun `python3 macos/configure.py` immediately after restore and check the web UI. `.aib` import does not import these application settings. Do not press a chapter's Download action unless you deliberately want the files.

For future remote access, keep the loopback binding and use a separately reviewed authenticated VPN/SSH forwarding arrangement with HTTPS where appropriate. Do not expose the bare HTTP port to a LAN or the internet. No remote access has been enabled.

## Aidoku migration: approval required before using a real backup

This setup has **not opened or imported any personal Aidoku backup**. First export a complete `.aib` from Aidoku and save a separate original outside its app container. Keep Aidoku installed and unchanged until you have verified the destination.

Based on `api/aidoku_backup.rs` and the shipped binary's disposable-fixture test:

- Saved library entries and online source/manga keys: supported **when the matching source is already installed**.
- Categories and membership: supported, including string and object category forms.
- Chapter read flags, last page, and read timestamps: supported. Existing progress merges by maximum page, OR of read state, and newer timestamp. A full historical event/session timeline is not imported; the importer preserves per-chapter history state.
- Supported tracker links: AniList, MyAnimeList, Bangumi, MangaBaka. Other tracker types are skipped with a reason.
- Source repository lists, installed source binaries, general Aidoku settings, source configuration/credentials, reading sessions, vocabulary, and downloaded pages: **not imported by the `.aib` path**. Add the same source repositories and install/configure sources separately in Browse before confirming the migration.
- Missing-source entries are skipped and reported. Do not approve an import with unexpected skips; install the exact matching source key and preview again. No automatic cross-app container migration or continuing Aidoku sync is provided.

The existing web UI's Settings backup/import action walks upload → **dry-run preview** → confirmation. The documented API is `POST /api/v1/backups/import/aidoku?dryRun=true`; preview executes the import transaction and rolls it back. The real import is additive. Neither importing metadata nor saving a title requires a chapter download. Verify category counts, several partly read chapters, and timestamps before trusting the result. Keep the original `.aib` untouched.

## Backups and recovery

The existing scheduler is enabled: **every 24 hours**, **30 newest files**, in the independent Documents backup folder. An overdue/first backup runs at startup; subsequent due checks occur about once a minute while the server runs. It writes a temporary file and renames it atomically, so partial writes are not listed as completed JSON backups. The startup backup was observed; a full 24-hour elapsed cycle and retention pruning have not been time-tested here.

Scheduled snapshots can legitimately be empty. The built-in scheduler does not reject an empty library, and old files eventually fall out of retention. After an approved migration and after verifying important changes, export JSON using the web UI and keep an additional validated checkpoint:

```sh
python3 macos/checkpoint.py "/path/to/exported-sumidoku-backup.json"
```

The helper performs basic shape checks and refuses malformed JSON, an unsupported version, invalid main sections, and an empty saved library. A successful checkpoint is not proof that every source is restorable; keep the original export and review a restore report in a disposable instance. It atomically publishes a unique snapshot and writes a SHA-256 sidecar **without replacing an existing file**. The scheduler does not prune the `checkpoints/` subdirectory. These pinned snapshots are the protection against later empty backups aging out good state; create one after the real library has been imported and checked. This command is intentionally not run on a personal backup without approval.

JSON export carries portable metadata and source settings, potentially including site credentials. It references source packages rather than bundling all application state. To preserve installed WASM packages, all source repositories, private app configuration, and the database itself, also make a **cold copy** of the full application directory:

```sh
./macos/service.sh stop
# Use a NEW destination each time; do not replace an earlier known-good copy.
ditto "$HOME/Library/Application Support/Sumidoku" \
  "$HOME/Documents/Sumidoku Backups/full-state-$(date +%Y%m%d-%H%M%S)"
./macos/service.sh start
```

Cold copies include private authentication/config files: store them privately. On another Mac, absolute download/backup paths in the restored config need updating. Keep the installed release version record with the copy and avoid database downgrades.

For JSON recovery, stop making changes, preserve the current data folder, install the matching sources, then restore a selected known-good JSON in Settings. Missing-source rows otherwise skip. Deselect settings to retain metadata-only behavior, or rerun `configure.py` after restoring. Review warnings and counts; restore never reconstructs downloaded chapters from metadata.

For full-state recovery, stop/disable the service, **rename the current data folder aside**, and restore a complete cold copy to the application location. Start using the same server release first, inspect logs, verify the library, then consider upgrades. Do not copy a live SQLite database while the server is writing it or delete the only copy of a damaged database before recovery is confirmed.

A backup on the same Mac does not survive disk loss. Use an external disk or another Mac you control; [Time Machine](https://support.apple.com/en-us/104984) is an existing macOS option. Ensure it includes both the application directory and the independent backup folder. An off-device destination was not configured because no backup disk was selected. This adds no cloud provider.

## Updates and uninstall

Before an update, export a nonempty checkpoint and make a cold full-state copy. Download the desired **official ARM64** release, verify its published SHA-256, stop the service, replace only `bin/sumidoku-server`, preserve the config and database, and start it again. Confirm `/health`, `/api/v1/version`, login, and sample progress. Do not rerun the fresh installer over an existing installation or automatically track an unpinned “latest” download.

To uninstall safely, disable the service and remove its plist/Dock item. Keep the data and independent backups until recovery has been checked elsewhere. The checkout can be removed separately; it is not the runtime data location. No uninstall command here deletes a library automatically.

## Verification record

Validated 2026-11-14 against official **1.23.3**; fork baseline **53d823cd560061da3a9f8f43baa8552a9c843c3f**.

Passed: release SHA-256; native ARM64 executable startup; health/version; launchd load and restart; one loopback listener; private file permissions; authenticated API access and anonymous rejection; persisted metadata-only settings; initial scheduled backup; existing sign-in UI rendering; existing library/category UI rendering against disposable data; fixture repository installation and source setting readback; synthetic `.aib` dry-run rollback/import with skip reports; category/page-progress preservation; JSON export and restore to a fresh disposable instance; restart persistence; invalid-version backup rejection with library unchanged; zero chapter downloads; checkpoint rejection/non-overwrite test; shell syntax checks.

Not performed: personal `.aib` import, external real-source connectivity/site login, full historical session migration (unsupported), elapsed 24-hour scheduling/retention pruning, real logout/login auto-start, off-device backup, manual login in the permanent client. The native app and Dock entry are now installed; see the native-app verification record for those checks. The permanent library remains empty. No Aidoku application/data, AidokuBlue project, or unrelated checkout was modified by this setup.

Re-run the focused checks without rebuilding the application:

```sh
python3 -m unittest discover -s macos/tests -v
python3 macos/smoke-test.py
# Optional: keep disposable test data open for a browser check; press Enter to clean up.
python3 macos/smoke-test.py --hold
```

The smoke test uses only local fixtures and a separate temporary Sumidoku instance on port 3301, and cleans it up. It refuses an occupied test port. Rust/clippy/frontend build suites were not run: no server, WASM runtime, or frontend source was changed; verification exercised the official released binary.
