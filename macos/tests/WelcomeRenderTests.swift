import AppKit
import SwiftUI

@main
@MainActor
struct WelcomeRenderTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let temporary = URL(fileURLWithPath: CommandLine.arguments[1])
        let helper = Bundle.main.url(forResource: "service", withExtension: "sh")!
        let manager = LibraryManager(home: temporary, binary: temporary.appendingPathComponent("missing-server"),
            runner: temporary.appendingPathComponent("missing-runner"), service: LaunchAgentService(helper: helper))
        let controller = ServerController(manager: manager)
        let host = NSHostingView(rootView: WelcomeView(controller: controller).frame(width: 800, height: 730).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 730), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.orderFrontRegardless()
        window.display()
        func capture(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Native view capture failed") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            try! data.write(to: temporary.appendingPathComponent(name + ".png"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            capture("welcome")
            controller.onboarding = "create"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                capture("create")
                controller.onboarding = "signin"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    capture("signin")
                    precondition(!FileManager.default.fileExists(atPath: manager.descriptor.path))
                    print("PASS: native welcome/create/sign-in rendered without creating an account or service")
                    app.stop(nil)
                    // Wake NSApplication's event loop after stop.
                    app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
                }
            }
        }
        app.run()
    }
}
