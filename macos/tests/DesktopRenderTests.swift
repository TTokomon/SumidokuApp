import AppKit
import SwiftUI
import WebKit

final class PreviewService: LibraryService {
    func loaded() -> Bool { false }
    func start(plist: URL) throws { throw UpdateFailure("Preview cannot manage services") }
    func stop() throws { throw UpdateFailure("Preview cannot manage services") }
    func restart() throws { throw UpdateFailure("Preview cannot manage services") }
}
@main
@MainActor
struct DesktopRenderTests {
    let controller: ServerController
    let updates: AppUpdates
    let root: URL
    let output: URL
    func wait(_ expression: String) async throws {
        for _ in 0..<150 {
            if (try? await controller.webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds:200_000_000)
        }
        throw UpdateFailure("UI fixture timed out: " + expression)
    }
    func capture(_ name: String) async throws {
        try await Task.sleep(nanoseconds:700_000_000)
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) else { throw UpdateFailure("Preview window missing") }
        try await OwnWindowCapture.save(window,webView:controller.nativePanel == nil ? controller.webView : nil,to:output.appendingPathComponent(name+".png"))
    }

    func captureAccessibility() async throws {
        for (name, reduced, contrast, fallback) in [("native-glass",false,false,false),("native-material-fallback",false,false,true),("reduced-transparency",true,false,false),("increased-contrast",false,true,false)] {
            let sample = VStack(alignment: .leading, spacing: 22) {
                Text("Native control surfaces").font(.title2.bold())
                Text(name).foregroundStyle(.secondary)
                NativeControlGroup {
                    HStack(spacing: 12) {
                        Label("Continue Reading", systemImage: "book").padding(14).modifier(NativeControlSurface(forceSystemMaterial: fallback, reduceTransparencyOverride: reduced, increasedContrastOverride: contrast))
                        SystemGlassAction(forceBordered: reduced || contrast || fallback, action: {}) { Label("Open Library", systemImage: "books.vertical") }
                    }
                }
            }.padding(32).frame(width: 600, height: 250, alignment: .leading)
            let window=NSWindow(contentRect:NSRect(x:100,y:100,width:600,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
            window.title="Sumidoku Accessibility Fixture"
            window.contentView=NSHostingView(rootView:sample)
            window.orderFrontRegardless();window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds:500_000_000)
            try await OwnWindowCapture.save(window,webView:nil,to:output.appendingPathComponent(name+".png"))
            window.close()
        }
    }
    func render() async {
        do {
                        fputs("UI fixture: loading library\n", stderr)
                        controller.webView.load(URLRequest(url:URL(string:"http://127.0.0.1:3309/library")!))
                        try await wait("document.querySelectorAll('.cover-card').length >= 4")
                        fputs("UI fixture: library loaded\n", stderr)
                        _ = try await controller.webView.evaluateJavaScript("localStorage.setItem('sumidoku.theme','light');location.reload()")
                        try await wait("document.querySelectorAll('.cover-card').length >= 4 && document.documentElement.dataset.theme === 'light'")
                        try await capture("library-light")
                        _ = try await controller.webView.evaluateJavaScript("localStorage.setItem('sumidoku.theme','dark');location.reload()")
                        try await wait("document.documentElement.dataset.theme === 'dark' && document.querySelectorAll('.cover-card').length >= 4")
                        try await capture("library-dark")
                        _ = try await controller.webView.evaluateJavaScript("localStorage.setItem('sumidoku.theme','light');location.reload()")
                        try await wait("document.documentElement.dataset.theme === 'light' && document.querySelectorAll('.cover-card').length >= 4")
                        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("preview.json"))) as! [String:Int]
                        let routes = [("manga-details","/manga/\(fixture["manga"]!)"),("sources","/browse"),("source-lists","/settings?section=source-lists"),("history","/history"),("backup-import","/settings?section=backups"),("reader","/reader/\(fixture["chapter"]!)")]
                        for (name,route) in routes {
                            controller.navigate(route)
                            try await wait("location.pathname + location.search === '\(route)'")
                            if name == "source-lists" {
                                try await wait("document.querySelector('input[aria-label=\"Automatically install source updates\"]') !== null")
                                _ = try await controller.webView.evaluateJavaScript("document.querySelector('input[aria-label=\"Automatically install source updates\"]').click()")
                                try await wait("Array.from(document.querySelectorAll('button')).some(b => b.textContent === 'Enable automatic source updates')")
                                _ = try await controller.webView.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(b => b.textContent === 'Enable automatic source updates').click()")
                                try await wait("document.querySelector('input[aria-label=\"Automatically install source updates\"]').checked")
                                _ = try await controller.webView.evaluateJavaScript("location.reload()")
                                try await wait("document.querySelector('input[aria-label=\"Automatically install source updates\"]')?.checked === true")
                                _ = try await controller.webView.evaluateJavaScript("document.querySelector('input[aria-label=\"Automatically install source updates\"]').click()")
                                try await wait("document.querySelector('input[aria-label=\"Automatically install source updates\"]').checked === false")
                                _ = try await controller.webView.evaluateJavaScript("document.querySelector('input[aria-label=\"Automatically refresh source lists\"]').click()")
                                try await wait("document.querySelector('input[aria-label=\"Automatically refresh source lists\"]').checked === false")
                                _ = try await controller.webView.evaluateJavaScript("document.querySelector('input[aria-label=\"Automatically refresh source lists\"]').click()")
                                try await wait("document.querySelector('input[aria-label=\"Automatically refresh source lists\"]').checked === true")
                            }
                            try await capture(name)
                        }
                        controller.nativePanel = "updates";try await capture("application-updates")
                        controller.nativePanel = "server";try await capture("native-server-settings")
                        try await captureAccessibility()
                        try JSONSerialization.data(withJSONObject:["success":true]).write(to:root.appendingPathComponent("render-result.json"))
                        print("PASS: native shell and embedded library/detail/sources/history/backups/reader/update/settings rendered; disposable fixtures only")
                        exit(0)
        } catch {
            try? JSONSerialization.data(withJSONObject:["success":false,"error":error.localizedDescription,"code":(error as NSError).code,"domain":(error as NSError).domain]).write(to:root.appendingPathComponent("render-result.json"))
            fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)
        }
    }
    static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let output=URL(fileURLWithPath:CommandLine.arguments[2])
        let manager=LibraryManager(home:root.appendingPathComponent("PreviewHome"),binary:root.appendingPathComponent("not-installed"),runner:root.appendingPathComponent("not-installed-runner"),service:PreviewService(),port:3309)
        let controller=ServerController(manager:manager,dataStore:.nonPersistent())
        controller.library=LocalLibrary(root:root,config:root,downloads:root.appendingPathComponent("Downloads"),backups:root.appendingPathComponent("Backups"))
        controller.available=true;controller.signedIn=true
        let updates=AppUpdates(defaults:UserDefaults(suiteName:"SumidokuUIFixture")!,schedule:false)
        let host=NSHostingView(rootView:DesktopShell(controller:controller,updates:updates).frame(minWidth:1080,minHeight:780))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:820),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="Sumidoku — Disposable UI Fixture"
        window.contentView=host;window.orderFrontRegardless();window.makeKeyAndOrderFront(nil);window.display()
        app.activate(ignoringOtherApps:true)
        let driver=Self(controller:controller,updates:updates,root:root,output:output)
        Task { await driver.render() }
        app.run()
    }
}
