# Sumidoku Desktop 1.3.1 — sidebar and Settings redesign

**Status:** Development branch only. No release, merge to `main`, local installation,
server replacement, library migration or cleanup has been performed here.

## Navigation

The native macOS `NavigationSplitView` sidebar now has exactly six destinations:

- Library
- Sources
- History
- Downloads
- Chapter Updates
- Settings

The first five are grouped under Collection. The one Settings entry is under
Preferences, replacing the ten individual Settings links. The same six
destinations are exposed by the browser-only fallback sidebar. This change does
not remove any old settings routes.

Original Sumidoku logo retained, displayed at 48pt with a larger name and
subtle Desktop caption. Native navigation glyphs are OS-rendered SF Symbols
chosen from Aidoku's original navigation system, at 22pt with restrained tints:
red Library, green Sources, orange History, blue Downloads, purple Updates,
neutral Settings. Native row height is at least 48pt. The sidebar's ideal
width is 270pt and is resizable. High contrast and the existing Liquid Glass
runtime fallback still use the platform's native surfaces. No Aidoku raster
assets or additional icon packs are bundled.

## Five Settings categories (web content under the native shell)

| Category | Existing subsections |
| --- | --- |
| Reading & Library | Reader, Library & Categories |
| Sources & Tracking | Source Lists, Trackers |
| Downloads & Backups | Downloads, Backups & Imports |
| Appearance & Updates | General, including theme and native application update bridge |
| Server & Account | System, security, API keys, caches, logs/about; native Server & Account controls via the local-only desktop bridge |

Each category has its own top-level button; categories with multiple sections
have a second row of subsection controls. The old `?section=general`,
`reader`, `library`, `trackers`, `downloads`, `backups`,
`source-lists` and `system` URLs stay valid and select the corresponding
category. All eight panel components remain mounted (inactive sections hidden)
so switching to Source Lists does not discard a selected Aidoku backup file.

The native `server` message is accepted only by the existing main-frame,
localhost-checked `WKScriptMessageHandler`. No new local service or network
endpoint has been created.

## Native sidebar footer

A single, compact native material surface contains two buttons:

- **App Updates:** actual update state and colored status. Neutral when unverified,
  green when verified current, orange when available, red for actual errors.
  The visible text is abbreviated for the sidebar and the accessibility label
  contains the complete result. Opens the existing native Updates panel.
- **Local Server:** actual server availability and colored state text. Opens
  the existing native Server & Account panel.

Status controls do not trigger an update or change the background service.

## Version

`macos/build-app.sh` sets **1.3.1 (7)** for development builds from this
branch. The user's currently installed 1.3.0 (6) remains unchanged.
No public 1.3.1 release or signed feed is published.

## Required before merge/install

Run on the Mac against a disposable test library first:

```sh
cd webui
npm run check
npm test
npm run build
cd ..
python3 -m unittest discover -s macos/tests -p 'test_*.py'
./macos/test-app.sh
./macos/test-updates.sh
python3 macos/test-desktop.py
```

Additional manual checks:

1. Visually inspect a real unlocked native window in light/dark, larger text,
   high contrast and reduced transparency. The original Sumidoku icon must
   remain unchanged.
2. Select each of the six sidebar entries and five Settings categories; use
   both internal Settings subsections and browser back/forward. Verify the
   selected state and no duplicate visible sidebar in WKWebView.
3. Open an existing Aidoku backup, navigate to Settings → Sources & Tracking →
   Source Lists and return. The backup file and exact-ID recovery state must
   survive. Confirm explicit removal choices still preserve library/progress.
4. Click App Updates and Local Server footer controls and verify that actual
   statuses and panel destinations are correct. Force offline/checking/error
   states; no false green state.
5. Confirm authenticated restart, one managed localhost server, account,
   library, categories, reading progress, sources, downloads and backups.
6. The app should not download chapters, install updates automatically or
   change signing policy as part of this UI-only change.

No Mac/Xcode runtime tests could be executed by the GitHub-only editing session.
Static regression tests were added but are **not yet locally verified**.
Keep the PR draft until the build, screenshot and preservation gates pass.
