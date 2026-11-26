"""Static sidebar regression guards; full rendering still requires Xcode on macOS."""
from pathlib import Path
import unittest
import re

ROOT = Path(__file__).resolve().parents[2]
SHELL = (ROOT / "macos/App/DesktopShell.swift").read_text(encoding="utf-8")
BRIDGE = (ROOT / "macos/App/SumidokuApp.swift").read_text(encoding="utf-8")


class Sidebar131Tests(unittest.TestCase):
    def test_collection_and_settings_destinations(self):
        collection = SHELL.split("static let collection = [", 1)[1].split("\n    ]", 1)[0]
        settings = SHELL.split("static let settings = [", 1)[1].split("\n    ]", 1)[0]
        self.assertEqual(re.findall(r'Self\(id: "([^"]+)"', collection),
                         ["/library", "/browse", "/history", "/downloads", "/updates"])
        self.assertEqual(re.findall(r'Self\(id: "([^"]+)"', settings),
                         [f"/settings?section={section}" for section in
                          ("general", "reader", "library", "source-lists", "downloads", "accounts", "system")])

    def test_navigation_symbol_identifiers_are_unique(self):
        navigation = SHELL.split("static let collection = [", 1)[1].split("var iconColor", 1)[0]
        symbols = re.findall(r'symbol: "([^"]+)"', navigation)
        self.assertEqual(len(symbols), 12)
        self.assertEqual(len(set(symbols + ["arrow.clockwise", "server.rack"])), 14)

    def test_original_logo_and_genuine_material_preserved(self):
        self.assertIn("NSImage.applicationIconName", SHELL)
        self.assertIn("NativeControlSurface()", SHELL)
        self.assertIn("NativeControlGroup", SHELL)
        self.assertIn("DesktopBrand.accent", SHELL)
        self.assertRegex(SHELL, r'frame\(width: 48, height: 48\)')
        self.assertRegex(SHELL, r'size: 18, weight: \.medium')
        self.assertRegex(SHELL, r'frame\(minHeight: 44, alignment: \.leading\)')
        self.assertIn('.listRowInsets(EdgeInsets(top: 0,', SHELL)
        self.assertIn('.clipped()', SHELL)

    def test_both_footer_destinations_open_native_controls(self):
        self.assertIn('controller.nativePanel = "updates"', SHELL)
        self.assertIn('controller.nativePanel = "server"', SHELL)
        self.assertIn("updates.color", SHELL)
        self.assertIn("controller.available", SHELL)
        self.assertIn("Open server controls.", SHELL)

    def test_legacy_settings_routes_select_current_preferences(self):
        self.assertIn('controller.route.hasPrefix("/settings")', SHELL)
        self.assertIn('case "reader": return "/settings?section=reader"', SHELL)
        self.assertIn('case "library", "automation": return "/settings?section=library"', SHELL)
        self.assertIn('case "source-lists": return "/settings?section=source-lists"', SHELL)
        self.assertIn('case "downloads", "backups": return "/settings?section=downloads"', SHELL)
        self.assertIn('case "system": return "/settings?section=system"', SHELL)
        self.assertIn('case "accounts", "trackers": return "/settings?section=accounts"', SHELL)
        self.assertIn('body["action"] == "server"', BRIDGE)


if __name__ == "__main__":
    unittest.main()
