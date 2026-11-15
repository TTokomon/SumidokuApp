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
        guard NativeSymbol.resolve("clock.arrow.2.circlepath", available: { $0 == "clock.arrow.circlepath" }) == "clock.arrow.circlepath",
              NativeSymbol.resolve("future.symbol", available: { $0 == "circle" }) == "circle" else {
            fputs("FAIL: older-system symbol fallback\n", stderr); exit(1)
        }
        print("PASS: \(count) actual native symbol resolutions and 2 older-system fallback cases")
    }
}
