"""Static sidebar regression guards; full rendering still requires Xcode on macOS."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL = (ROOT / "macos/App/DesktopShell.swift").read_text(encoding="utf-8")
BRIDGE = (ROOT / "macos/App/SumidokuApp.swift").read_text(encoding="utf-8")


class Sidebar131Tests(unittest.TestCase):
    def test_collection_and_settings_destinations(self):
        collection = SHELL.split("static let collection = [", 1)[1].split("\n    ]", 1)[0]
        settings = SHELL.split("static let settings = [", 1)[1].split("\n    ]", 1)[0]
        self.assertEqual(collection.count("Self(id:"), 5)
        self.assertEqual(settings.count("Self(id:"), 1)
        self.assertIn('Self(id: "/settings", title: "Settings", symbol: "gear")', settings)

    def test_original_logo_and_genuine_material_preserved(self):
        self.assertIn("NSImage.applicationIconName", SHELL)
        self.assertIn("NativeControlSurface()", SHELL)
        self.assertIn("NativeControlGroup", SHELL)
        self.assertIn("DesktopBrand.accent", SHELL)
        self.assertRegex(SHELL, r'frame\(width: 48, height: 48\)')
        self.assertRegex(SHELL, r'size: 22, weight: \.semibold')

    def test_both_footer_destinations_open_native_controls(self):
        self.assertIn('controller.nativePanel = "updates"', SHELL)
        self.assertIn('controller.nativePanel = "server"', SHELL)
        self.assertIn("updates.color", SHELL)
        self.assertIn("controller.available", SHELL)
        self.assertIn("Open server controls.", SHELL)

    def test_legacy_settings_routes_select_single_destination(self):
        self.assertIn('controller.route.hasPrefix("/settings")', SHELL)
        self.assertIn('return "/settings"', SHELL)
        self.assertIn('body["action"] == "server"', BRIDGE)


if __name__ == "__main__":
    unittest.main()
