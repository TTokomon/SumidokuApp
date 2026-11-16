# Sumidoku Desktop 1.3.1 (7) — final sidebar review

The revised sidebar was pulled at `a8eb608`. The final runtime build is
`250c0c4`, including the query-aware active-selection correction in `417043c`.
The installed 1.3.0 (6), persistent library and existing server are preserved.
This PR remains draft; no merge, installation or release is performed here.

## Final design

The original Sumidoku mark remains **48pt**. Native navigation uses **18pt**
medium SF Symbols, a 26pt icon column, comfortable 44pt minimum rows and
consistent semantic colors. Native Liquid Glass and its existing system-material
fallbacks are preserved; no custom icon artwork is added.

**Collection:** Library, Sources, History, Downloads, Chapter Updates.

| Preferences, in order | Legacy section | Contents |
| --- | --- | --- |
| General | `general` | Appearance, language, application updates |
| Reader | `reader` | Reading modes, gestures, incognito reading |
| Library | `library` | Categories, library display, chapter refresh |
| Sources | `source-lists`, `trackers` | Source Lists, source updates, trackers |
| Downloads & Backups | `downloads`, `backups` | Downloads, backups, import/restore |
| Server & Account | `system` | Server controls, account, security, cache, diagnostics |

Both native and browser-only sidebars expose eleven destinations. The root
`/settings` selects General; all eight historical query-section links remain
valid. Trackers selects Sources and backups selects Downloads & Backups. All
eight Settings panels remain mounted, preserving Aidoku recovery while managing
Source Lists. Browser query-aware links now expose exactly one `aria-current`
destination, rather than inheriting pathname-only NavLink selection.

App Updates and Local Server retain their compact native footer controls and
actual status. Opening a footer panel changes neither the server nor its service.
The main-frame localhost check on the native bridge remains intact.

## Focused verification

| Check | Result |
| --- | --- |
| TypeScript | Passed |
| Frontend sidebar, Settings, import rendering and locale checks | 20 passed |
| Native sidebar/symbol regression guards | 7 passed |
| Native application build | One build; 1.3.1 (7), strict signature verified |
| Embedded frontend | Six index/assets matched the frontend build byte for byte |
| Native route/legacy selection/footer/Aidoku recovery | Passed: 11 destinations, 9 legacy/root links, both footer clicks and exact-file recovery |
| Screenshots | Passed: exactly one light and one dark native capture |

The current-destination regression was deliberately broken from committed green:
pathname-only NavLink marked six Preferences links current. Restoring the single
file returned the focused assertion to green. Three stale assertions and the
unused earlier category labels were removed or updated.

Reproduce only the relevant checks:

```sh
npm --prefix webui run check
(cd webui && node --test tests/sidebar-layout.test.ts tests/settings-layout.test.ts tests/desktop-design.test.ts tests/settings-import.test.ts tests/i18n.test.ts)
python3 -m unittest macos.tests.test_sidebar_131 macos.tests.test_aidoku_symbols
CARGO_BUILD_JOBS=1 ./macos/build-fork.sh
SUMIDOKU_SERVER_BINARY="$PWD/dist/fork/sumidoku-server" SUMIDOKU_TEST_SIDEBAR_ONLY=1 python3 macos/test-desktop.py
```

The focused preview uses a disposable library, checks eleven selection bindings,
root Settings plus eight legacy URLs, both actual footer clicks, six categories,
eight persistent panels, back/forward and exact-byte Aidoku backup resume. It
saves only `library-light.png`, `library-dark.png` and verification metadata.
The existing extended fixture remains available for broader future work.

## Cleanup

Removed only verified obsolete or redundant artifacts:

- Four earlier six-destination 1.3.1 app copies (including the superseded review
  copy), plus three emptied app staging directories. One final staged app remains.
- Six old temporary capture directories containing 108 files, plus the final
  temporary capture copy (three files) after preserving the canonical pair/metadata.
- Twenty-six older verification logs. Current focused logs and regression evidence
  are retained with the final staged app.
- Eight superseded tracked variants: `footer-available.png`, `footer-error.png`,
  `footer-offline.png`, `reduced-transparency.png`, `sidebar-increased-contrast.png`,
  `sidebar-large-text.png`, `sidebar-small.png`, `source-lists.png`.
- Thirty unused translation entries: `categoryReadingLibrary`,
  `categorySourcesTracking`, `categoryAppearanceUpdates` in ten locale catalogs.
  Three stale single/five-category assertions were updated, and one unused Python
  import was removed. Useful extended test drivers remain; the focused mode
  avoids running them for this small change.

The two canonical images and verification JSON replace the earlier design's
copies. The exact local removed/replaced path inventory is `cleanup.json` beside
the staged app. Latest evidence, useful test sources, compiler caches, historical
1.3.0 documentation and every personal/installed component are retained. Finder
folder metadata was preserved. The installed 1.3.0 executable is byte-identical;
the same existing server remains the sole localhost listener.

## Review images

These are the final eleven-destination native captures using
original disposable comic fixtures; no personal library data is published.

![Final light sidebar](images/sidebar-131/library-light.png)
![Final dark sidebar](images/sidebar-131/library-dark.png)

## Remaining gates

Full Rust/Clippy, the complete frontend suite and remote CI are not certified on
this head by this focused UI review. Mandatory repository merge gates remain
incomplete; previous broader results do not certify this revision. Actual older
hardware, global accessibility settings and reboot behavior remain separate checks.

The app is ad-hoc signed for local review, not notarized for public distribution.
Unsigned automatic application installation stays disabled. No manga chapters are
automatically downloaded, and no server/data migration or installation occurs.
Do not merge PR #4, replace the installed app or publish 1.3.1 without approval.
