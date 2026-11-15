"""Regression guards for Aidoku-aligned, OS-rendered SF Symbols.

No Aidoku image assets or application branding are bundled.
See docs/AIDOKU_SYMBOLS.md for upstream provenance.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL = ROOT / "macos/App/DesktopShell.swift"


class AidokuSymbolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code = SHELL.read_text(encoding="utf-8")

    def test_main_navigation_uses_aidoku_symbol_identifiers(self):
        mapping = {
            'id: "/library", title: "Library"': "books.vertical.fill",
            'id: "/browse", title: "Sources"': "globe",
            'id: "/history", title: "History"': "clock.fill",
            'id: "/downloads", title: "Downloads"': "arrow.down.circle.fill",
        }
        for destination, symbol in mapping.items():
            with self.subTest(destination=destination):
                self.assertIn(f'{destination}, symbol: "{symbol}"', self.code)

    def test_settings_symbols_follow_aidoku(self):
        mapping = {
            "source-lists": "globe",
            "reader": "book.fill",
            "library": "books.vertical.fill",
            "downloads": "arrow.down.circle.fill",
            "backups": "externaldrive.fill",
            "system": "info.circle.fill",
        }
        for section, symbol in mapping.items():
            with self.subTest(section=section):
                self.assertIn(f'id: "/settings?section={section}",', self.code)
                self.assertIn(
                    f'id: "/settings?section={section}", title: ',
                    self.code
                )
                line = next(line for line in self.code.splitlines()
                            if f'id: "/settings?section={section}",' in line)
                self.assertIn(f'symbol: "{symbol}"', line)

    def test_original_sumidoku_app_logo_is_retained(self):
        self.assertIn("NSImage.applicationIconName", self.code)
        self.assertIn('Text("Sumidoku")', self.code)


if __name__ == "__main__":
    unittest.main()
