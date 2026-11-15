# Sumidoku.app for macOS

The desktop client is a genuine SwiftUI application with an embedded WKWebView, installed at `/Applications/Sumidoku.app`. It is not a Safari web app, shortcut, PWA, or browser launcher. It displays the existing Sumidoku interface at `http://127.0.0.1:3000` and does not rebuild the frontend.

## Use the app

Open **Sumidoku** from the Dock or Applications. The installed bundle is registered with LaunchServices for Finder and application discovery; Spotlight indexing may take a moment.

Sign in once with the existing admin login. The client never reads the private server config or admin password. WebKit has its own persistent cookie/site-data store, so Safari's existing session is not copied into the app. Login continues to be handled by the existing Sumidoku server and web interface.

- **Command-comma:** native Settings, with status, Start Server, Restart Server, Open Data Folder, Open Logs, and Open Backups.
- **Command-R:** check the server and reload the interface.
- **Command-W:** close the active window.
- **Command-Q:** quit the client. The background server and scheduled backups continue running.
- The standard app, File, Edit, View, Server, Window, and Help menus provide native commands. Edit actions use the web view's responder chain.

If the server is unavailable, a native error screen provides **Start Server** and **Check Again**. Start loads the existing user LaunchAgent; it does not install a server or make another Sumidoku database. Restart signals the registered job gracefully and waits for its new runner and health endpoint. The app checks local health periodically while its main window is open and reloads after recovery. Closing the main window and reopening the app brings its window back.

The existing web interface retains its own import/export controls. File uploads use a native Open panel, and exports use a native Save panel through WebKit's download delegate. Choose a new filename for exports; WebKit can reject an existing destination. No personal backup is imported or exported automatically. Intentional external links open in the default browser; the core library interface stays in the native app. External OAuth/provider flows have not been verified inside this client.

## Existing server and data

The client uses only the previously installed Sumidoku server and `app.sumidoku.server` LaunchAgent. It does not bundle or launch a second server executable, change the listener, alter authentication, or write library/source/download/backup settings. The server remains bound to loopback. Settings' folder buttons open the existing data, logs, and backup folders.

The desktop client is not App Sandbox restricted, because its native controls must call the existing user LaunchAgent and open the existing folders. No privileged helper or root daemon is installed. The control subprocess gets an explicit minimal HOME/PATH environment rather than inheriting GUI launch variables. The client does not stop the server on application termination.

## Build and install

Requirements: Apple Silicon, macOS 13 or later, full Xcode with command-line tools, and Python 3 for generating the bundle metadata. This client was built with Xcode 27.1 on macOS 26.6.2; older supported macOS versions have not been runtime-tested.

From the repository root:

```sh
./macos/build-app.sh
# For a first installation, when /Applications/Sumidoku.app does not exist:
./macos/build-app.sh --install
```

Output: `dist/native/Sumidoku.app`, a native arm64 executable with an application icon derived from the existing Sumidoku artwork. `dist/` is ignored by Git. No Cargo/npm frontend or server build runs.

`--install` refuses to replace an existing application. For a client update, quit Sumidoku first, build it, and replace only its application bundle:

```sh
./macos/build-app.sh
ditto --norsrc --noextattr dist/native/Sumidoku.app /Applications/Sumidoku.app
# Remove only Finder/resource-fork metadata on this generated app, if present.
xattr -dr com.apple.FinderInfo /Applications/Sumidoku.app 2>/dev/null || true
xattr -dr com.apple.ResourceFork /Applications/Sumidoku.app 2>/dev/null || true
codesign --verify --strict /Applications/Sumidoku.app
open /Applications/Sumidoku.app
```

Do not remove the application-support data folder when updating the client. The server may stay running throughout an app-only update. The installer requires write permission to Applications; no sudo was needed in the verified installation.

The build defaults to **ad-hoc signing** (`codesign --sign -`). Local code-signature verification passes and the application launched locally. It has no Developer ID team identity and is **not notarized**: `spctl --assess` rejects this build for trusted distribution. This does not mean its local signature check failed. A downloaded copy may trigger Gatekeeper; production distribution requires a Developer ID signature and notarization. A developer may pass `SIGNING_IDENTITY` to use an existing signing identity; notarization is not automated here. No signing certificate or team identifier is committed.

The scripts remove only FinderInfo/ResourceFork metadata from generated app bundles, which otherwise prevents code signing after copies from a file-provider-managed directory. They do not disable Gatekeeper or clear quarantine globally. See the specific-app approval guidance in [macOS setup](MACOS_SETUP.md).

## Verification

Verified 2026-11-14:

- Native arm64 SwiftUI/WKWebView executable compiled and installed in Applications; bundle metadata and strict code signature verified.
- Dedicated Sumidoku application window rendered the existing sign-in interface at the required loopback URL, independently of Safari.
- Native Settings opened with Command-comma and reported the server status and expected controls.
- With the server stopped, the app showed its native unavailable screen and Start Server button. Clicking it loaded the existing LaunchAgent and returned to the sign-in interface.
- Clicking native Restart Server returned to Running, and the embedded interface loaded afterward. The retained LaunchAgent restart avoids a GUI unload/bootstrap race.
- Command-Q exited the client; the existing server remained healthy with the **same server process ID**. The app was reopened afterward.
- One native Sumidoku Dock entry was added while preserving other Dock entries. The application was registered with LaunchServices.
- Twelve Swift navigation-policy cases passed, rejecting nonlocal/lookalike hosts, wrong schemes/ports, file URLs, and embedded credentials.
- Python service/checkpoint regression tests and shell syntax checks passed. The restart regression was also checked red with the unregister/rebootstrap path and green after restoring the retained-job signal path.

Not performed: entry of the existing admin password, validation of a real logged-in session across app relaunch, personal library/backup operations, native file upload/export dialogs with personal data, external provider OAuth, older-macOS runtime tests, Developer ID signing/notarization, or a real logout/login cycle. No server/frontend source was changed, so Cargo and frontend build suites were not rerun. The prior disposable server import/restore smoke checks remain documented in [macOS setup](MACOS_SETUP.md).

Run focused checks:

```sh
./macos/test-app.sh
python3 -m unittest discover -s macos/tests -v
bash -n macos/build-app.sh macos/service.sh macos/test-app.sh
```

## Redundant-component cleanup

The post-install audit found one native client, one user LaunchAgent, and one
backend listener bound to loopback. No Sumidoku Safari web app was found in
the system or user Applications folders, and no duplicate Sumidoku service
plist was found in the user/system LaunchAgents or system LaunchDaemons.
No service configuration or persistent storage needed modification.

The obsolete Safari action in `macos/service.sh open` now launches the installed
native app. Its bundled copy was updated and the client re-signed and reopened.
The backend kept the same PID and remained healthy throughout. No dependency
was installed solely for the abandoned browser-app method, so none was removed.

Removed only confirmed disposable development artifacts (about 292 MiB):

- Checkout `dist/native/`: generated app copy, Swift module cache, iconset,
  and compiled navigation-test executable; then its empty `dist/` parent.
- Python bytecode caches under `macos/` and `macos/tests/`.
- Temporary `sumidoku-1.23.3-arm64.tar.gz`, `sumidoku-release-extract/`,
  and `sumidoku-release.json`: verified installer download, extracted duplicate
  server/README, and release metadata. The extracted server matched the installed
  binary before removal.
- Temporary `sumidoku-app-build.log`, `sumidoku-app-build-final.log`,
  `sumidoku-restart-red.log`, `sumidoku-cleanup-red.log`, and
  `sumidoku-server-before-quit.pid`: development build/test output and PID note.
- Temporary `sumidoku-app-cleanup-rollback.app`: client-only rollback copy,
  removed after installed signature, launch, helper equality, and health checks.
- Temporary cleanup inventory/preservation JSON reports after verification.

No disposable server database was found left over from the self-cleaning smoke
tests. All test source and fixtures remain. WebKit runtime storage was retained.
Configuration, LaunchAgent, server binary, and runner hashes were unchanged;
all preexisting backup files remained present. The application-support data
folder, downloads, source repositories, login credentials, backup schedule,
Aidoku installations/backups, and unrelated projects were left intact.

Desktop and Downloads could not be inspected because macOS denied directory
access; nothing there was removed. Unknown shortcuts or user data were not
classified as disposable. The cleanup audit therefore covers the accessible
installation, service, checkout, and temporary-file locations, rather than
claiming an exhaustive scan of protected folders.

Validation: five isolated Python helper/checkpoint tests pass. The native-open
regression fails with the old Safari command and passes after restoring the
committed native command. Strict installed signature verification passes; the
client runs independently, and the original loopback backend remains healthy.
The earlier native-window, offline recovery, restart, and quit checks above
remain applicable; this cleanup changed only the launcher helper and docs.
