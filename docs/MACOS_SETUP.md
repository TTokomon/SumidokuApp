# Native macOS setup and recovery

Use [Sumidoku.app's native onboarding](NATIVE_APP.md) to create a local owner account
and choose storage, or sign in to an existing installation. The application never
creates a generated password behind the scenes. The build/cache procedure is in
that guide; `macos/install.py` now caches only the pinned official server binary.

The pinned release is **1.23.3**, ARM64 macOS. Archive SHA-256:

```text
c6fcd267ab03cc456199fbc556ed1b7b8b49c41f8c0858f63e90b7eeb05318a1
```

The packaged server binary SHA-256 is checked separately by the native build.
No Docker, Rust build, npm install or additional runtime package is needed. The
native client uses only macOS frameworks and the official executable.

## Storage and controls

The selected primary folder owns `Server/`, `Downloads/`, and `Backups/`. Database,
source repositories, installed source packages, metadata, categories and progress
share the Server config directory. Downloads and backups have explicit separate
paths. Server logs remain under `~/Library/Logs/Sumidoku/`. The binary/runner and
path-only descriptor stay under `~/Library/Application Support/Sumidoku/`; they do
not store a plaintext password after successful owner setup. A single user
LaunchAgent manages the background server. It listens only on localhost.

Use native Settings for status, start/restart, account credentials, folder buttons,
backup/restore and sign-out. Shell helpers remain optional maintenance tools:

```sh
./macos/service.sh status
./macos/service.sh start
./macos/service.sh restart
./macos/service.sh stop
./macos/service.sh open
```

`open` opens the native app. `stop` unloads the service for the current login;
`disable` and `enable` additionally control future logins. Quitting/signing out
never unloads the service. Do not launch another server against the same database.

The owner chooses the credentials. Startup seeding is removed after setup and
confirmed recovery; password hashes persist in the database. Use native Change
Password or the explicitly confirmed Forgot Password workflow. Do not paste private
configuration/recovery copies into GitHub or chat. Recovery copies may contain old
credentials and must remain private.

## Reading and backups

Saving a title stores metadata. Automatic chapter downloads and reader download-ahead
are disabled at creation; manual offline downloads remain allowed. Reader caches
are separate from offline download files. Restoring a JSON settings section can
change download preferences; deselect settings or review them afterward. The optional
`macos/configure.py` maintenance command prompts for credentials, applies these
defaults and verifies readback; it never reads a plaintext password from config.

Daily snapshots retain the newest 30 matching backup files under the selected
Backups folder. Initial/overdue backup runs at startup; elapsed 24-hour scheduling
and pruning still need a time-based check. Native credential changes first save
private cold `Recovery-*` directories there; the scheduler does not prune them.
Backups on the same disk do not cover disk loss. Use Time Machine or another private
external destination for both the selected library and important recovery copies.

Before restoring personal data, preserve a full cold copy and the original export.
The upstream Backup and Restore section includes JSON export/restore, Aidoku import
preview, warnings and section selectors. For a validated, nonempty JSON checkpoint:

```sh
python3 macos/checkpoint.py "/path/to/exported-sumidoku-backup.json" \
  --destination "/path/to/Sumidoku Library/Backups/checkpoints"
```

The helper checks shape/nonempty library and refuses replacing existing snapshots.
Its default destination is the original independent backup folder; pass `--destination`
for a chosen library's Backups/checkpoints folder (see the helper's actual options).
This basic validation is not proof every source can be restored. Never overwrite the
only recovery copy or copy a live writing SQLite database as a cold snapshot.

## Aidoku migration

No personal Aidoku backup has been opened or imported by this setup. Keep Aidoku
and its original backup unchanged until the destination is verified. Install the
matching source repositories/packages before previewing an `.aib` import. Missing
sources are skipped and reported; investigate unexpected skips before confirmation.

The tested importer preserves saved entries, category membership, chapter read flags,
last page and read timestamps. Progress merges by maximum page, OR of read state,
and newer timestamp. Supported tracker links include AniList, MyAnimeList, Bangumi
and MangaBaka. Full historical sessions, source packages/repository lists, source
credentials/configuration and downloaded pages are not imported by the `.aib` path.
There is no continuing cross-app sync. Review category counts and partly read chapters
before trusting a migration; retain original Aidoku data and backups.

## Verification commands

```sh
./macos/test-onboarding.sh
./macos/test-onboarding.sh --launchagent
./macos/test-app.sh
./macos/test-welcome.sh
python3 -m unittest discover -s macos/tests -v
python3 macos/smoke-test.py
```

All fixtures and synthetic databases use separate temporary directories and loopback
ports. See the native guide for actual results and remaining interactive checks.
No command here deletes a personal library or merges the draft PR.
