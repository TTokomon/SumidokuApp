import AppKit
import Foundation

@main
@MainActor
struct NativeSymbolTests {
    static func main() {
        _ = NSApplication.shared
        var count = 0
        for item in DesktopDestination.collection + DesktopDestination.settings {
            let resolved = NativeSymbol.resolve(item.symbol)
            guard NSImage(systemSymbolName: resolved, accessibilityDescription: nil) != nil else {
                fputs("FAIL: unresolved native symbol for \(item.title)\n", stderr); exit(1)
            }
            count += 1
            print("PASS: \(item.title): \(item.symbol) → \(resolved)")
        }
        let symbols = (DesktopDestination.collection + DesktopDestination.settings).map(\.symbol) + ["arrow.clockwise", "server.rack"]
        let actual = symbols.map { NativeSymbol.resolve($0) }
        guard Set(symbols).count == 13, Set(actual).count == 13 else {
            fputs("FAIL: duplicate navigation identifiers or current-system resolutions\n", stderr); exit(1)
        }
        // Simulate preferred names being absent; these base glyphs exist on supported older systems.
        let older: Set<String> = ["books.vertical", "network", "clock", "arrow.down.circle", "clock.arrow.circlepath", "gearshape", "book", "calendar", "externaldrive", "person.crop.circle", "gearshape.2", "goforward", "desktopcomputer"]
        let fallback = symbols.map { NativeSymbol.resolve($0, available: { older.contains($0) }) }
        guard Set(fallback).count == 13, fallback.allSatisfy({ older.contains($0) && NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }) else {
            fputs("FAIL: older-system fallback unavailable or collision\n", stderr); exit(1)
        }
        print("PASS: \(count) actual destination resolutions; 13 unique current and 13 collision-free forced older-system sidebar/footer resolutions")
    }
}
