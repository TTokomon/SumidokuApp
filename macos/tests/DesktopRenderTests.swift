import AppKit
import SwiftUI
import WebKit

final class PreviewService: LibraryService {
    func loaded() -> Bool { false }
    func start(plist: URL) throws { throw UpdateFailure("Preview cannot manage services") }
    func stop() throws { throw UpdateFailure("Preview cannot manage services") }
    func restart() throws { throw UpdateFailure("Preview cannot manage services") }
}
actor PreviewReleases: ReleaseFetching {
    var mode = "empty"
    func select(_ value: String) { mode = value }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let selected = mode
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if selected == "offline" { throw URLError(.notConnectedToInternet) }
        let bytes: Data
        if selected == "error" { bytes = Data("invalid release metadata".utf8) }
        else if selected == "available" {
            bytes = try JSONSerialization.data(withJSONObject: [["id":1,"tag_name":"1.4.0","name":"Fixture release","body":"Disposable metadata only","html_url":"https://github.com/TTokomon/SumidokuApp/releases/tag/fixture","draft":false,"prerelease":false,"assets":[["name":"Sumidoku-Desktop-fixture-macOS-arm64.zip","browser_download_url":"https://github.com/TTokomon/SumidokuApp/releases/download/fixture/update.zip"]]]])
        } else { bytes = Data("[]".utf8) }
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
@main
@MainActor
struct DesktopRenderTests {
    let controller: ServerController
    let updates: AppUpdates
    let releases: PreviewReleases
    let root: URL
    let output: URL
    let port: Int
    func wait(_ expression: String) async throws {
        for _ in 0..<150 {
            if (try? await controller.webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(nanoseconds:200_000_000)
        }
        throw UpdateFailure("UI fixture timed out: " + expression)
    }
    var sidebarOnly: Bool { CommandLine.arguments.contains("--sidebar-only") }
    var capturesEnabled: Bool { !CommandLine.arguments.contains("--no-capture") }
    func clickOwnWindow(_ window: NSWindow, at point: NSPoint) async throws {
        window.makeKeyAndOrderFront(nil)
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw UpdateFailure("Own-window test event unavailable") }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
    }
    func verifyNativeNavigation() async throws {
        let shell = DesktopShell(controller: controller, updates: updates)
        for item in DesktopDestination.collection + DesktopDestination.settings {
            shell.selection.wrappedValue = item.id
            try await wait("location.pathname + location.search === '\(item.id)'")
            guard shell.selection.wrappedValue == item.id else { throw UpdateFailure("Native sidebar selection mismatch") }
        }
        for (route, target, selected) in [("/settings", "/settings", "/settings?section=general"), ("/settings?section=general", "/settings?section=general", "/settings?section=general"), ("/settings?section=reader", "/settings?section=reader", "/settings?section=reader"), ("/settings?section=library", "/library?panel=organize", "/library"), ("/settings?section=source-lists", "/browse?view=lists", "/browse"), ("/settings?section=trackers", "/settings?section=trackers", "/settings?section=accounts"), ("/settings?section=downloads", "/settings?section=downloads", "/settings?section=downloads"), ("/settings?section=backups", "/settings?section=backups", "/settings?section=downloads"), ("/settings?section=system", "/settings?section=system", "/settings?section=system")] {
            controller.navigate(route)
            try await wait("location.pathname + location.search === '\(target)'")
            guard shell.selection.wrappedValue == selected else { throw UpdateFailure("Legacy Settings selection mismatch") }
        }
        guard let window = controller.webView.window else { throw UpdateFailure("Native window missing") }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await clickOwnWindow(window, at: NSPoint(x: 100, y: 64))
        guard controller.nativePanel == "updates", shell.selection.wrappedValue == "/settings?section=general" else { throw UpdateFailure("App Updates footer destination mismatch") }
        try await clickOwnWindow(window, at: NSPoint(x: 100, y: 40))
        guard controller.nativePanel == "server" else { throw UpdateFailure("Local Server footer destination mismatch") }
        controller.navigate("/library")
        try await wait("location.pathname === '/library'")
        print("PASS: eleven native selection bindings and own-window clicks on both native footer controls")
    }
    func verifyGroupedSettingsAndRecovery() async throws {
        controller.navigate("/settings?section=backups")
        try await wait("document.querySelectorAll('[data-settings-category]').length === 6 && document.querySelectorAll('[data-settings-panel]').length === 8")
        for section in ["general", "reader", "automation", "downloads", "backups", "accounts", "trackers", "system"] {
            controller.navigate("/settings?section=" + section)
            try await wait("document.querySelector('[data-settings-panel=\"\(section)\"]').hidden === false")
        }
        controller.webView.goBack()
        try await wait("location.search === '?section=trackers'")
        controller.webView.goForward()
        try await wait("location.search === '?section=system'")
        controller.navigate("/settings?section=backups")
        try await wait("document.querySelector('[data-settings-panel=backups]').hidden === false")
        let backup = try Data(contentsOf: root.appendingPathComponent("example.aib")).base64EncodedString()
        _ = try await controller.webView.evaluateJavaScript("""
        window.__aibBodies=[];const originalFetch=window.fetch;
        window.fetch=async function(input,options){
            if(String(input).includes('/backups/import/aidoku') && options?.body instanceof Blob){
                window.__aibBodies.push(Array.from(new Uint8Array(await options.body.arrayBuffer())).join(','));
            }
            return originalFetch.call(this,input,options);
        };
        const bytes=Uint8Array.from(atob('\(backup)'),c=>c.charCodeAt(0));
        const transfer=new DataTransfer();transfer.items.add(new File([bytes],'example.aib'));
        const input=document.querySelector('input[accept=".aib"]');input.files=transfer.files;input.dispatchEvent(new Event('change',{bubbles:true}));
        """)
        try await wait("document.querySelector('[aria-label=\"Recover Missing Aidoku Sources\"]') !== null")
        try await wait("document.querySelector('[aria-label=\"Recover Missing Aidoku Sources\"] input[type=checkbox]') !== null")
        try await run("document.querySelector('[aria-label=\"Recover Missing Aidoku Sources\"] input[type=checkbox]').click();")
        try await wait("document.querySelector('[aria-label=\"Recover Missing Aidoku Sources\"] input[type=checkbox]').checked")
        _ = try await controller.webView.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(b=>b.textContent==='Add / Manage Source Lists…').click()")
        try await wait("location.pathname === '/browse' && location.search === '?view=lists' && document.querySelector('section[aria-label=\"Source Lists\"]') !== null")
        controller.navigate("/settings?section=backups")
        try await wait("Array.from(document.querySelectorAll('button')).some(b=>b.textContent==='Resume Aidoku Import')")
        _ = try await controller.webView.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(b=>b.textContent==='Resume Aidoku Import').click()")
        try await wait("document.querySelector('[aria-label=\"Recover Missing Aidoku Sources\"]') !== null && window.__aibBodies.length === 2 && window.__aibBodies[0] === window.__aibBodies[1] && document.querySelector('[aria-label=\"Recover Missing Aidoku Sources\"] input[type=checkbox]')?.checked === true")
        _ = try await controller.webView.evaluateJavaScript("Array.from(document.querySelector('[role=dialog]').querySelectorAll('button')).find(b=>b.textContent==='Cancel').click()")
        print("PASS: six visible Settings categories, eight persistent panels, subsections/back-forward and exact same Aidoku backup resumed after Source Lists")
    }
    func capture(_ name: String) async throws {
        guard capturesEnabled else { return }
        try await Task.sleep(nanoseconds:700_000_000)
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) else { throw UpdateFailure("Preview window missing") }
        if !sidebarOnly && controller.nativePanel == nil {
            let view = controller.webView
            guard view.window === window, view.bounds.width > 500, view.bounds.height > 400 else { throw UpdateFailure("Embedded web view has no visible layout: \(view.bounds)") }
            let snapshot = try await view.takeSnapshot(configuration: nil)
            if let tiff = snapshot.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png,properties:[:]) {
                try png.write(to:output.appendingPathComponent(name+"-webview.png"))
            }
        }
        try await OwnWindowCapture.save(window,webView:controller.nativePanel == nil ? controller.webView : nil,to:output.appendingPathComponent(name+".png"))
    }

    func captureAccessibility() async throws {
        guard capturesEnabled else { return }
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
    func captureSidebarVariants() async throws {
        guard capturesEnabled else { return }
        guard let window = controller.webView.window else { throw UpdateFailure("Sidebar variant window missing") }
        controller.navigate("/settings?section=source-lists")
        try await wait("location.search === '?section=source-lists'")
        window.setContentSize(NSSize(width: 920, height: 640))
        try await capture("sidebar-small")
        window.setContentSize(NSSize(width: 1120, height: 820))
        controller.webView.pageZoom = 1.35
        try await capture("sidebar-large-text")
        controller.webView.pageZoom = 1
        window.appearance = NSAppearance(named: .accessibilityHighContrastAqua)
        try await capture("sidebar-increased-contrast")
        window.appearance = nil
    }
    func verifyFooterStates() async throws {
        controller.navigate("/library")
        try await wait("location.pathname === '/library'")
        for (mode, expected) in [("offline", AppUpdateState.offline), ("error", .error), ("empty", .unavailable), ("available", .available)] {
            await releases.select(mode)
            updates.check()
            guard updates.state == .checking else { throw UpdateFailure("Footer did not enter checking state") }
            if mode == "offline" { try await capture("footer-checking") }
            await updates.waitForCheck()
            guard updates.state == expected, !updates.canInstall else { throw UpdateFailure("Footer state or installation policy mismatch") }
            try await capture("footer-" + mode)
        }
    }
    func render() async {
        do {
                        fputs("UI fixture: loading library\n", stderr)
                        controller.webView.load(URLRequest(url:URL(string:"http://127.0.0.1:\(port)/library")!))
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
                        try await verifyNativeNavigation()
                        try await verifyLibraryWorkspace()
                        try await verifyAutomationAndTrackers()
                        try await verifyGroupedSettingsAndRecovery()
                        if sidebarOnly {
                            try JSONSerialization.data(withJSONObject:["success":true,"mode":"focused-sidebar","nativeWindowCaptures":capturesEnabled,"nativeDestinations":11,"legacySettingsRoutes":9,"nativeFooterActions":2,"settingsCategories":6,"persistentSettingsPanels":8,"aidokuExactFileResumed":true,"recoverySelectionPreserved":true,"libraryOrganization":true,"settingsPersisted":true,"trackerControlsFixtureVerified":true]).write(to:root.appendingPathComponent("render-result.json"))
                            exit(0)
                        }
                        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("preview.json"))) as! [String:Int]
                        let routes = [("manga-details","/manga/\(fixture["manga"]!)"),("sources","/browse"),("source-lists","/browse?view=lists"),("automation","/settings?section=automation"),("history","/history"),("backup-import","/settings?section=backups"),("reader","/reader/\(fixture["chapter"]!)")]
                        for (name,route) in routes {
                            controller.navigate(route)
                            try await wait("location.pathname + location.search === '\(route)'")
                            if name == "automation" {
                                try await wait("document.querySelector('input[aria-label=\"Automatically install source updates\"]') !== null")
                                _ = try await controller.webView.evaluateJavaScript("document.querySelector('input[aria-label=\"Automatically install source updates\"]').click()")
                                try await wait("Array.from(document.querySelectorAll('button')).some(b => b.textContent === 'Enable automatic source updates')")
                                _ = try await controller.webView.evaluateJavaScript("Array.from(document.querySelectorAll('button')).find(b => b.textContent === 'Enable automatic source updates').click()")
                                try await wait("document.querySelector('input[aria-label=\"Automatically install source updates\"]').checked")
                                _ = try await controller.webView.evaluateJavaScript("window.__fixtureReloadMarker='old';location.reload()")
                                try await wait("window.__fixtureReloadMarker === undefined && document.querySelector('input[aria-label=\"Automatically install source updates\"]')?.checked === true")
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
                        try await captureSidebarVariants()
                        try await verifyFooterStates()
                        try await captureAccessibility()
                        try JSONSerialization.data(withJSONObject:["success":true,"nativeWindowCaptures":capturesEnabled,"nativeDestinations":11,"nativeFooterActions":2,"footerFixtureStates":4,"settingsCategories":6,"persistentSettingsPanels":8,"aidokuExactFileResumed":true]).write(to:root.appendingPathComponent("render-result.json"))
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
        guard let rawPort = try? String(contentsOf: root.appendingPathComponent("fixture-port"), encoding: .utf8),
              let port = Int(rawPort), (1024...65535).contains(port), port != 3000 else {
            fputs("Invalid disposable UI port.\n", stderr)
            exit(1)
        }
        let manager=LibraryManager(home:root.appendingPathComponent("PreviewHome"),binary:root.appendingPathComponent("not-installed"),runner:root.appendingPathComponent("not-installed-runner"),service:PreviewService(),port:port)
        let controller=ServerController(manager:manager,dataStore:.nonPersistent())
        controller.library=LocalLibrary(root:root,config:root,downloads:root.appendingPathComponent("Downloads"),backups:root.appendingPathComponent("Backups"))
        controller.available=true;controller.checking=false;controller.signedIn=true
        let fixtureScript = try! String(contentsOf: root.appendingPathComponent("tracker-fixture.js"), encoding: .utf8)
        controller.webView.configuration.userContentController.addUserScript(WKUserScript(source: fixtureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let releases = PreviewReleases()
        let updates=AppUpdates(defaults:UserDefaults(suiteName:"SumidokuUIFixture."+root.lastPathComponent)!,schedule:false,fetcher:releases)
        let host=NSHostingView(rootView:AnyView(DesktopShell(controller:controller,updates:updates).frame(minWidth:780,minHeight:600)))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:CommandLine.arguments.contains("--sidebar-only") ? 1000 : 820),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="Sumidoku — Disposable UI Fixture"
        window.contentView=host;window.orderFrontRegardless();window.makeKeyAndOrderFront(nil);window.display()
        app.activate(ignoringOtherApps:true)
        let driver=Self(controller:controller,updates:updates,releases:releases,root:root,output:output,port:port)
        Task { await driver.render() }
        app.run()
    }
}
