# Aidoku's native symbols in Sumidoku Desktop

This change reuses the **exact SF Symbol identifiers** that Aidoku itself
selects in its UIKit/SwiftUI source code; macOS renders the icons using
Apple's installed system glyphs. No Aidoku image, app-icon asset, code
implementation, or compiled icon file has been copied or embedded.

## Verified upstream sources

- [Aidoku tab bar](https://github.com/Aidoku/Aidoku/blob/main/Aidoku/App/Root/TabBarController.swift)
  — `books.vertical.fill` (Library), `globe` (Browse), `clock.fill`
  (History), and `gear` (Settings).
- [Aidoku settings icons](https://github.com/Aidoku/Aidoku/blob/main/Aidoku/Features/Settings/Settings.swift)
  — `books.vertical.fill` (Library), `book.fill` (Reader),
  `clock.arrow.2.circlepath` (Tracking), `gearshape.2.fill`
  (Advanced), `info.circle.fill` (About), `globe` (Source Lists),
  `externaldrive.fill` (Backups), and `arrow.down.circle.fill`
  (Downloads).

Our native sidebar uses those original symbol *names* instead of inventing
new pictograms. Chapter Updates/Application Updates reuse Aidoku's circular
update symbol as a visual analogy; they are not Aidoku navigation tabs.
Server & Account reuses Aidoku's advanced-settings symbol.

The native shell continues to use genuine system Liquid Glass where
supported. Its bundled **Sumidoku logo and red accent remain unchanged**.

## Scope and licensing

- Aidoku's source tree (other than translations) is [GPLv3-licensed](https://github.com/Aidoku/Aidoku/blob/main/LICENSE).
  Its original branded logo and raster assets should **not** be copied
  into this MIT-origin project without separately reviewing copyright,
  attribution, trademark identity, and the distribution's GPL compliance.
- SF Symbols are supplied by Apple's operating system, not by Aidoku's
  repository. Referencing the same public system symbol identifiers does
  not incorporate Aidoku's GPLv3 images or code into our binary.
- The React/WKWebView content uses its existing Lucide icons. Reusing
  SF Symbols natively does not turn web icons into SF Symbols, and
  SF Symbols are not converted to exported SVGs or font files for the web.
- The upstream Aidoku application name and logo are never substituted
  for Sumidoku's app identity.

## Verification

A lightweight regression suite:
`python3 -m unittest macos/tests/test_aidoku_symbols.py`

The complete native build and on-device rendering still require testing
on macOS with Xcode. No installed user application, data, or backup has
been modified from this branch.

Before merging: run Python maintenance tests and the native rendering
fixtures. Check all SF Symbols resolve on the oldest supported deployment
target, and inspect the updated sidebar in the actual installed app.
