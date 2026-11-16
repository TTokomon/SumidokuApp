import AppKit
import WebKit

@main
@MainActor
struct SourceUIRenderTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: "window.__sourceUIErrors=[];window.addEventListener('error',e=>window.__sourceUIErrors.push(e.message));window.addEventListener('unhandledrejection',e=>window.__sourceUIErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 950), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        let address = CommandLine.arguments[1]
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        func js(_ script: String) async throws -> Any? { try await web.evaluateJavaScript(script) }
        func waitFor(_ script: String) async throws {
            for _ in 0..<150 {
                if (try? await js(script)) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw NSError(domain: "SourceUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out: \(script)"])
        }
        func capture(_ name: String) async throws {
            try await Task.sleep(nanoseconds: 500_000_000)
            let image = try await web.takeSnapshot(configuration: nil)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        Task {
            do {
                web.load(URLRequest(url: URL(string: address + "/browse")!))
                try await waitFor("document.querySelectorAll('[data-integration]').length === 4 && document.body.textContent.includes('External Sources')")
                try await capture("sources")
                for kind in ["local", "komga", "kavita", "suwayomi"] {
                    _ = try await js("Array.from(document.querySelector('[data-integration=\"\(kind)\"]').querySelectorAll('button')).find(b=>b.textContent.trim()==='Set Up').click()")
                    try await waitFor("document.querySelector('[role=dialog]') !== null && document.body.innerText.includes('Test Connection') && document.body.innerText.includes('Save Connection')")
                    _ = try await js("Array.from(document.querySelector('[role=dialog]').querySelectorAll('button')).find(b=>b.textContent.trim()==='Cancel').click()")
                    try await waitFor("document.querySelector('[role=dialog]') === null")
                }
                web.load(URLRequest(url: URL(string: address + "/settings?section=source-lists")!))
                try await waitFor("document.querySelector('section[aria-label=\"Source Lists\"]') !== null && document.querySelector('[data-settings-group=\"source-lists\"][aria-current=\"page\"]') !== null && document.querySelectorAll('[data-settings-category]').length === 5")
                try await capture("source-lists")
                _ = try await js("Array.from(document.querySelectorAll('button')).find(b=>b.textContent.trim()==='Add Source List').click()")
                try await waitFor("document.querySelector('[aria-label=\"GitHub repository or published Aidoku index URL\"]') !== null")
                print("PASS: WKWebView rendered Sources, all four setup/test forms, dedicated Source Lists and Add Source List; no repository required")
                exit(0)
            } catch {
                print("Test URL:", web.url?.absoluteString ?? "none")
                print("Disposable document:", (try? await js("JSON.stringify({text:document.body.innerText,errors:window.__sourceUIErrors})")) ?? "unavailable")
                try? await capture("failure")
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
