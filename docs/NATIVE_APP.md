# Sumidoku.app for macOS

Sumidoku.app is a SwiftUI application containing WKWebView. It reuses the released
server and existing web interface, with one owner, one localhost server, one user
LaunchAgent, and a persistent library outside the application bundle.

## First launch

Open Sumidoku from Applications, Finder, Spotlight, or the Dock. A clean installation
shows **Create New Library** and **Sign In**. Launching the app does not install a
service, create an account, or start a second database.

**Create New Library** asks for your username, password and confirmation, and a
storage folder. The default is `~/Documents/Sumidoku Library/`; **Choose Storage
Folder** opens the native folder picker. Choose a new or empty folder. A folder
containing files is rejected without overwriting it; use Sign In to reconnect an
existing library. The account belongs to this local server, not an internet service.
There is one owner, with no invented multi-user registration.

The chosen primary folder contains:

- `Server/`: configuration, database, source packages, cover/page caches, and related
  server state. Source repositories, library membership, categories and reading
  progress live in the database. These share a config root as upstream requires.
- `Downloads/`: intentional offline chapter downloads only.
- `Backups/`: daily JSON snapshots (30-file retention), and private `Recovery-*`
  cold snapshots created before native credential changes. Recovery folders are
  outside the scheduler's filename-based pruning and are never deleted by the app.

Saving a title stores metadata; automatic chapter downloads and download-ahead
start disabled. Reading can cache individual pages under Server. Cached reader
pages are distinct from intentionally downloaded offline chapters. Manual downloads
remain available in the existing interface.

**Sign In** detects the saved installation or lets you select an existing library
folder. It authenticates with your username/password and reuses the database and
settings. It may load the matching existing LaunchAgent, or reconstruct a missing
agent for a validated existing library; it never creates another database. A
conflicting service, occupied port, unsupported configuration, wrong password or
unavailable server produces an error. Existing configurations must explicitly
specify quoted localhost address, download path and backup path; unsupported TOML
is rejected safely rather than guessed. A missing/disconnected library is retained.

## Account and server controls

Command-comma opens native Settings: status, account username, storage path, Open
Library Folder, Open Logs, Open Backups, Start/Restart, Change Password, Backup and
Restore, and Sign Out. Backup and Restore opens the upstream backup section in the
native window, retaining its upload, dry-run preview and section selection.

Change Password verifies the current password, briefly stops the server for a
private recovery snapshot, removes startup credential overrides, and changes the
server's stored password hash. **Forgot Password** on Sign In offers explicit local
owner recovery, with a confirmation toggle. It stops and snapshots the existing
library, seeds the user-chosen replacement credentials once, verifies login, and
removes the active seed. It retains all library data. This is a local macOS owner's
recovery action; filesystem access to the library is already privileged access.
Close other connected clients before maintenance if their live streams prevent
a clean shutdown. The native app tears down its own document/event stream before
server or credential controls and reloads afterward. No workflow disables authentication or deletes a database to recover access.

Passwords exist transiently in secure fields and a private mode-600 bootstrap
config while the server creates its hash. On successful setup/recovery the active
config contains no password override. The server database owns the persistent hash,
so later native or web password changes remain effective after restart. Failed
recovery retains a private cold copy; if startup fails before seed cleanup, inspect
and recover that protected installation before retrying. No password/token goes in
UserDefaults, the descriptor, Git, command arguments, or logs. WebKit stores the
server's HttpOnly session cookie; Safari sessions are not copied.

Signing out revokes the current session and removes the app's session cookie. It
leaves the service, data and backups intact. Quitting also leaves the service running.
The app never starts a service until explicit create/connect/start/recovery action.
When an existing server is unavailable, the native error screen offers Start Server.

Command-R checks/reloads, Command-W closes the active window, and Command-Q quits.
Standard macOS menus, the existing icon, native file pickers, and upload/download
panels remain available. The chosen folder and owner state survive client updates.

## Native shell and application updates

The redesigned sidebar, toolbar and update controls use system SwiftUI/AppKit, including real Liquid Glass on macOS 26 and native material fallbacks. App update checking is operational; unattended app/server installation remains gated on release signing and certified coordination. See [design, operational status and release instructions](DESKTOP_DESIGN.md).

## Source integrations

The current feature build uses the separately named [source integrations fork](SOURCE_INTEGRATIONS.md). Follow that guide to build and activate Built-in Sources and Settings → Source Lists. The official-only commands below remain available for the base upstream client. Native Settings → Source Lists opens the single repository manager inside the application window.

## Runtime and build

The small runtime descriptor at `~/Library/Application Support/Sumidoku/desktop-library.json`
stores only folder paths. The same support directory retains the pinned binary and
runner under `bin/`; the LaunchAgent remains `app.sumidoku.server`. New configurations
bind exclusively to `127.0.0.1:3000`. The runner clears inherited server environment
overrides and forwards termination as SIGINT for graceful shutdown. There is no Docker,
server rebuild, frontend rebuild, or server reinstall per launch. Build-time dependencies are documented in the source integrations guide.

On Apple Silicon with Xcode and Python available, cache the pinned official server
binary once if needed, then build the client:

```sh
python3 macos/install.py
./macos/build-app.sh --install
```

The binary-only cache command creates no account, configuration, database or service.
The build packages the verified official binary for first-time explicit setup; an
existing installed binary is reused. Nothing downloads during normal app launch.

For an existing client, quit it and update only its application bundle:

```sh
./macos/build-app.sh
ditto --norsrc --noextattr dist/native/Sumidoku.app /Applications/Sumidoku.app
xattr -dr com.apple.FinderInfo /Applications/Sumidoku.app 2>/dev/null || true
xattr -dr com.apple.ResourceFork /Applications/Sumidoku.app 2>/dev/null || true
codesign --verify --strict /Applications/Sumidoku.app
open /Applications/Sumidoku.app
```

Signing is ad-hoc for local development. Strict signature verification passes, but
this build has no Developer ID identity or notarization and Gatekeeper distribution
assessment rejects it. A downloaded distribution needs appropriate signing/notarization.
Gatekeeper is never disabled. Signing stages outside file-provider directories to
avoid Finder metadata invalidating the seal. Client updates preserve all server data.

## Verification and limitations

`./macos/test-onboarding.sh` runs actual pinned-server lifecycle checks against
disposable directories on a separate loopback port. `--launchagent` repeats them
using a unique temporary macOS launchd label and the real graceful runner. No test
uses the permanent database or chosen personal credentials. The jobs and fixture
directories are removed after the checks.

Passed: 32 lifecycle assertions with each of the direct-process and real temporary
LaunchAgent drivers, 12 navigation
policy cases, and seven Python installer/service/checkpoint tests. Native welcome,
create and sign-in views were rendered by an isolated AppKit/SwiftUI test app without
creating an owner or service. The seed-removal assertion was verified red when active seed cleanup was removed
and green after restoring the committed manager. The transient-unload regression
was verified red with a single bootout attempt and green with the committed retry.
The lifecycle test also authenticates an actual
WKWebView with the native login cookie, clears it on sign-out, and tears down its
live document before graceful service shutdown.

Covered: clean descriptor state; owner/password validation; custom storage; server
startup and existing HTML; authentication/sign-out/sign-in; descriptor recreation;
password change and old-password rejection after restart; explicit credential
recovery after service unload/reload; preservation of synthetic source files,
category/library rows and reading progress; recovery snapshots; download defaults;
existing-folder byte-for-byte protection; reconnect; and injected startup failure
leaving no new database, descriptor or LaunchAgent. Existing Swift navigation,
Python checkpoint/service and fixture import/export tests remain available.

The reset of the original generated installation was authorized only after checking
it contained no manga, chapters, categories, source repositories or download files.
The job was stopped, a private cold recovery copy was integrity-checked, and only
its active generated config, empty database/sidecars and obsolete LaunchAgent were
retired. Its cached binary, original scheduled backup and recovery copy were retained.
No replacement account was created. The installed client is left at first-run setup;
removal of the recovery copy requires explicit owner confirmation after the new
library works.

Interactive completion of the new native forms/folder picker, the final chosen
credentials, a persistent WebKit session across an actual app relaunch, a full Mac
logout/login or reboot, and elapsed backup scheduling/retention remain manual checks.
The lifecycle suite exercises real service unload/reload, not a complete macOS login.
No personal Aidoku backup was opened or imported. Server/frontend source is unchanged;
Cargo and frontend build suites were not rerun.

## Earlier disposable-component cleanup

The prior cleanup removed about 292 MiB: generated `dist/native/` builds/module
cache/iconset/test executable and empty parent; Python bytecode; temporary official
release archive/extracted duplicate binary/release metadata; development build and
regression logs/PID note; a temporary client rollback copy and audit scratch reports.
No Sumidoku Safari web app or duplicate service was found in accessible Applications
and service locations. The old Safari launcher now opens the native application.
No abandoned-method dependency required removal. Useful test sources/fixtures and
WebKit runtime storage were retained. Desktop and Downloads were inaccessible and
untouched. No Aidoku, Aidoku backups, AidokuBlue or unrelated project was modified.
