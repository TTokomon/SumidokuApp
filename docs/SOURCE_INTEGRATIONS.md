# Sources and source lists

The native client embeds the existing Sumidoku interface. **Sources** separates
**Built-in Sources** from **External Sources**. **Settings → Source Lists** is the
only subscription manager; the native Settings shortcut opens this same page.

## Built-in connections

All four setup cards are present before subscribing to any list. Test Connection
validates access without creating a source or downloading chapters. Save validates
again and persists the connection. Existing connections can be edited.

- **Local Files:** choose one or more folders with the native picker (or enter
  server-local paths). Sumidoku's existing local scanner and supported formats are
  reused. Scan Folders is explicit; no manga files are copied or deleted.
- **Komga:** use its OPDS catalog URL, for example `https://komga.example/opds/v2/catalog`,
  and the server's username/password. Existing OPDS Atom and OPDS 2 readers are reused.
- **Kavita:** paste the private OPDS URL from the server's third-party client settings.
  It may contain an API key. Optional HTTP Basic credentials are supported.
- **Suwayomi:** enter the server base URL, optionally with HTTP Basic credentials.
  The adapter calls its supported GraphQL endpoint (`api/graphql`) to browse/search
  the remote saved library, fetch chapters and stream pages when reading. It does
  not install extensions, enqueue downloads or synchronize reading progress back
  to Suwayomi. Interactive JWT/OIDC login is not implemented. This is a live API
  connection, separate from backup import.

Built-in connections require no GitHub repository. Connection tests report HTTP,
TLS, schema, filesystem and authentication failures inline. Redirects are rejected;
use the final endpoint. HTTPS links cannot downgrade to HTTP. HTTP Basic credentials
are attached only to the configured origin. Self-signed certificates require a
properly trusted certificate; TLS verification is never disabled.

Connection secrets are encrypted with ChaCha20-Poly1305. The encryption key is a
private, mode-600 file in the existing server configuration directory. Passwords
and private OPDS endpoints are omitted from public source metadata. Stable opaque
fetch locators prevent API-key-bearing OPDS links from leaking into library metadata.
A portable JSON export does not include the encryption key: retain a private full
cold copy of the Server directory, including `integration-secrets.key`, when moving
an installation. Without that key, reconnect remote integrations using new credentials.
Never share a full Server copy publicly.

## External Sources and Source Lists

Installed external sources show IDs, versions, update state and origin. Browse
available sources with text, language, rating and Source List filters. Single-source
install/update and confirmed multiple-source installation reuse upstream package APIs.
Installing a package does not download manga chapters.

In **Settings → Source Lists**, add either a published Aidoku JSON index URL or a
GitHub repository URL. GitHub discovery probes known published Pages/raw index
locations; a repository without a compatible index is rejected. No repository code,
workflows or build scripts are executed. Lists can be named/renamed, refreshed and
removed. Failed refreshes preserve cached entries and expose the fetch error.

Index entries, IDs, URLs, redirects, package manifest identity/version and readable
WASM payloads are checked before replacing a package. Reserved built-in namespaces
cannot be registered as external packages. Discovery does not guarantee that every
third-party package works with this runtime. Only install lists you trust.

Removing a list offers two explicit choices: keep installed packages, or uninstall
its packages while keeping library/progress records. Uninstalling an external source
also retains those records. Reinstalling the exact source ID reconnects them. Package
removal is distinct from deleting library manga or removing a subscription. Legacy
API callers retain their existing destructive source-delete behavior unless they
request `keepData=true`; the new interface always requests preservation.

## Aidoku backup recovery

The `.aib` preview identifies missing source IDs and lists exact matches from
subscribed lists and installed packages. Select matching packages and confirm before
installation, then recheck the same original backup. Add missing GitHub lists through
Source Lists and return to Backups → Resume Import. The selected file remains in
memory while switching settings sections; select it again after closing/reloading.

Source display names never establish identity. The preview retains exact skip
reasons and requires acknowledgement if entries remain unsupported. Manga,
categories and progress are imported only after the separate import confirmation.
The original file and preexisting library are retained. The workflow does not search
arbitrary repositories or claim it knows a list that has never been subscribed to.

## Building and activating this fork

The official release is unchanged and cached separately. This feature requires the
explicit source-integrations fork of the pinned upstream tree, not the official
executable. With Rust/Cargo, Node/npm, Python and Xcode available:

```sh
cd webui && npm ci && cd ..
./macos/build-fork.sh
python3 macos/activate-fork.py
```

The native build stages the signed bundle outside file-provider folders and records
its location in the untracked `dist/fork/native-build.json` for activation.
The build embeds the production web UI into the Rust release, records source/artifact
hashes in `dist/fork/server-build.json`, and bundles it into the ad-hoc-signed native
client. Activation quits the client, stops the existing job, saves a private cold
recovery copy, and selects **a separate `sumidoku-server-fork` executable** through the
same LaunchAgent/runner and existing configuration. It does not overwrite the pinned
`sumidoku-server`, create another database or install another service. It verifies
account/library/progress fingerprints and explicitly disables automatic chapter
downloads and download-ahead. All other settings, original downloads and backup
locations remain. Keep the generated `fork-upgrade-*` recovery directory until an
explicit decision to remove it. Gatekeeper notarization limitations are unchanged.

For upstream updates, review/rebase the feature commits against the next pinned
release, run the full checks below, rebuild the explicit fork and activate through
the same backup-first process. Do not replace the official artifact or use an
unreviewed upstream binary as if it contained these features.

```sh
cargo nextest run --workspace
cargo clippy --workspace --all-targets -- -D warnings
cd webui && npm run check && npm test && npm run build && cd ..
./macos/test-app.sh
./macos/test-onboarding.sh
python3 macos/test-sources.py
python3 -m unittest discover -s macos/tests -p 'test_*.py'
```

Integration tests use temporary databases and local HTTP/GraphQL fixtures for all
four built-in paths, authentication errors, real page streaming, package updates,
subscription removal/reinstall and exact-ID Aidoku recovery. These do not constitute
certification against every installed Komga/Kavita/Suwayomi release or a user's
private server. Public-index discovery can additionally be checked manually in a
disposable installation; automated tests never contact public repositories.

API references: [Suwayomi contribution/API guide](https://github.com/Suwayomi/Suwayomi-Server/blob/master/CONTRIBUTING.md),
[Suwayomi schema](https://github.com/Suwayomi/Suwayomi-VUI/blob/main/schema.graphql),
[Komga OPDS](https://komga.org/docs/guides/opds/),
[Kavita OPDS](https://wiki.kavitareader.com/guides/features/opds/).
