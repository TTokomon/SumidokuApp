import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopen: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopen?()
        return true
    }
}

@MainActor
final class ServerController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandlerWithReply {
    var address: URL { manager.api.base }
    @Published var available = false
    @Published var checking = true
    @Published var operation: String?
    @Published var message = ""
    @Published var controlError: String?
    @Published var library: LocalLibrary?
    @Published var username = ""
    @Published var signedIn = false
    @Published var onboarding = "welcome"
    let manager: LibraryManager
    @Published var route = "/library"
    @Published var routeTitle = "Library"
    @Published var nativePanel: String?
    var showUpdates: (() -> Void)?
    var checkAppUpdates: (() -> Void)?
    let webView: WKWebView
    private var navigationGeneration = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    private var sessionGeneration = 0
    private var probing = false
    private var loaded = false
    private let session: URLSession

    init(manager injectedManager: LibraryManager? = nil, dataStore: WKWebsiteDataStore? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? .default()
        configuration.userContentController.addUserScript(WKUserScript(source: "window.__sumidokuVersion=\(LibraryManager.quote(Bundle.main.object(forInfoDictionaryKey: "SumidokuReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"));\n" + Self.shellScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        let network = URLSessionConfiguration.ephemeral
        network.timeoutIntervalForRequest = 2
        network.timeoutIntervalForResource = 3
        session = URLSession(configuration: network)
        let support = InstallationContext.home.appendingPathComponent("Library/Application Support/Sumidoku/bin")
        let helper = Bundle.main.url(forResource: "service", withExtension: "sh")!
        let runtime = Bundle.main.url(forResource: "server-build", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let executable = runtime?["variant"] as? String == "fork" ? "sumidoku-server-fork" : "sumidoku-server"
        manager = injectedManager ?? LibraryManager(home:InstallationContext.home,binary: support.appendingPathComponent(executable),
                                 runner: support.appendingPathComponent("run-server.sh"),
                                 service: LaunchAgentService(helper: helper),port:InstallationContext.port)
        super.init()
        do { library = try manager.current(); if library != nil { onboarding = "signin" } }
        catch { controlError = error.localizedDescription }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "chooseLocalFolders")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "desktop")
        webView.allowsBackForwardNavigationGestures = true
        webView.publisher(for: \.canGoBack).receive(on: RunLoop.main).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).receive(on: RunLoop.main).assign(to: &$canGoForward)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, NavigationPolicy.isLocal(url, port: manager.api.base.port ?? 3000) else {
            replyHandler(nil, "Folder selection is restricted to the local library interface.")
            return
        }
        if message.name == "desktop" {
            if let body = message.body as? [String: String] {
                if body["action"] == "updates" || body["action"] == "checkUpdates" { showUpdates?() }
                if body["action"] == "server" { nativePanel = "server" }
                if body["action"] == "checkUpdates" { checkAppUpdates?() }
                if let path = body["path"], path.hasPrefix("/"), !path.hasPrefix("//") { route = path }
                if let title = body["title"] { routeTitle = String(title.prefix(120)).replacingOccurrences(of: " · Sumidoku", with: "") }
                if let theme = body["theme"] { NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua) }
            }
            replyHandler(true, nil); return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Choose Manga Folders"
        panel.begin { result in replyHandler(result == .OK ? panel.urls.map(\.path) : [], nil) }
    }

    static let shellScript = """
    window.__sumidokuDesktop = true;
    const ready = () => {
        document.documentElement.dataset.nativeShell = 'true';
        const notify = () => window.webkit.messageHandlers.desktop.postMessage({path:location.pathname+location.search,title:document.title,theme:document.documentElement.dataset.theme||'light'}).catch(()=>{});
        new MutationObserver(notify).observe(document.documentElement,{attributes:true,attributeFilter:['data-theme']});
        const title = document.querySelector('title'); if(title) new MutationObserver(notify).observe(title,{childList:true});
        window.addEventListener('popstate',notify);
        for (const name of ['pushState','replaceState']) { const old=history[name]; history[name]=function(...args){const result=old.apply(this,args);notify();return result;}; }
        notify();
    };
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',ready,{once:true});else ready();
    """
    func navigate(_ path: String) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"), path.utf8.count <= 2048 else { return }
        nativePanel = nil
        let data = try! JSONSerialization.data(withJSONObject: [path])
        let encoded = String(data: data, encoding: .utf8)!
        navigationGeneration += 1
        let generation = navigationGeneration
        webView.evaluateJavaScript("window.__sumidokuRouterReady === true ? (window.dispatchEvent(new CustomEvent('sumidoku:navigate',{detail:\(encoded)[0]})),true) : false") { [weak self] result, _ in
            guard let self, generation == self.navigationGeneration else { return }
            if result as? Bool != true, let url = URL(string: path, relativeTo: self.address) { self.webView.load(URLRequest(url: url)) }
        }
    }
    func readerKey(_ key: String) {
        guard route.hasPrefix("/reader/"), ["PageUp","PageDown"].contains(key) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new KeyboardEvent('keydown',{key:'\(key)',bubbles:true}))")
    }

    func cookieHeader() async -> String {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return LocalAPI.cookieHeader(cookies.filter { $0.name == "sumidoku.session" && ["127.0.0.1", "localhost"].contains($0.domain) })
    }

    func accept(_ login: APIReply, library: LocalLibrary) async {
        for cookie in login.cookies { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
        self.library = library
        username = (login.json["user"] as? [String: Any])?["username"] as? String ?? ""
        signedIn = true; available = true; loaded = true; controlError = nil
        webView.load(URLRequest(url: address))
        bootstrapCommunitySourceList()
    }

    func prepareRuntime() throws {
        try manager.privateDirectory(manager.binary.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: manager.binary.path) {
            guard let packaged = Bundle.main.url(forResource: "sumidoku-server", withExtension: nil) else {
                throw LibraryFailure(text: "The packaged server is missing. Reinstall the app.")
            }
            try FileManager.default.copyItem(at: packaged, to: manager.binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.binary.path)
        }
        guard let runner = Bundle.main.url(forResource: "run-server", withExtension: "sh") else {
            throw LibraryFailure(text: "The server runner is missing.")
        }
        // Only explicit setup installs the runner; app launch never installs a server.
        if !FileManager.default.fileExists(atPath: manager.runner.path) {
            try FileManager.default.copyItem(at: runner, to: manager.runner)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: manager.runner.path)
        }
    }

    func authenticate(create: Bool, root: URL, username: String, password: String, confirmation: String) async {
        guard operation == nil else { return }
        sessionGeneration += 1
        operation = create ? "Creating your library…" : "Signing in…"; controlError = nil
        defer { operation = nil; checking = false }
        do {
            try prepareRuntime()
            let manager = self.manager
            let result = try await Task.detached {
                if create { return try manager.create(root: root, username: username, password: password, confirmation: confirmation) }
                return try manager.connect(root: root, username: username, password: password)
            }.value
            await accept(result.1, library: result.0)
        } catch { controlError = error.localizedDescription }
    }

    func signOut() async {
        guard operation == nil else { return }
        sessionGeneration += 1
        operation = "Signing out…"
        defer { operation = nil }
        try? await WebSessionQuiescer.suspend(webView)
        let cookie = await cookieHeader()
        let api = manager.api
        _ = try? await Task.detached { try api.request("api/v1/auth/logout", method: "POST", cookie: cookie) }.value
        for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() {
            if cookie.name == "sumidoku.session" { await webView.configuration.websiteDataStore.httpCookieStore.deleteCookie(cookie) }
        }
        signedIn = false; username = ""; loaded = false; onboarding = "signin"; controlError = nil
    }

    func passwordAction(current: String, new: String, confirmation: String, owner: String, recovery: Bool) async {
        guard let library = library, operation == nil else { return }
        sessionGeneration += 1
        operation = recovery ? "Recovering local owner access…" : "Changing password…"; controlError = nil
        defer { operation = nil }
        let cookie = await cookieHeader()
        let manager = self.manager
        do {
            try await WebSessionQuiescer.suspend(webView)
            let reply = try await Task.detached {
                if recovery { return try manager.recoverPassword(library: library, username: owner, new: new, confirmation: confirmation) }
                return try manager.changePassword(library: library, current: current, new: new, confirmation: confirmation, cookie: cookie)
            }.value
            await accept(reply, library: library)
        } catch {
            controlError = error.localizedDescription
            operation = nil
            await check(reload: true)
        }
    }

    func check(reload: Bool = false) async {
        guard !probing, operation == nil else { return }
        guard library != nil else { checking = false; return }
        probing = true
        let generation = sessionGeneration
        defer { probing = false; checking = false }
        let cookie = await cookieHeader()
        let api = manager.api
        do {
            let status = try await Task.detached { try api.request("api/v1/auth/status", cookie: cookie) }.value
            guard generation == sessionGeneration, operation == nil else { return }
            available = true; message = ""
            let identity = status.json["username"] as? String
            signedIn = identity != nil
            username = identity ?? ""
            if signedIn { bootstrapCommunitySourceList(cookie: cookie) }
            if signedIn && (!loaded || reload) {
                loaded = true
                webView.load(URLRequest(url: address))
            }
            if !signedIn { loaded = false; onboarding = "signin" }
        } catch {
            guard generation == sessionGeneration, operation == nil else { return }
            available = false
            message = "The local server is unavailable. Start it to open your library."
        }
    }

    func bootstrapCommunitySourceList(cookie: String? = nil) {
        guard signedIn, let library else { return }
        Task { [weak self] in
            guard let self else { return }
            let sessionCookie = if let cookie { cookie } else { await self.cookieHeader() }
            self.manager.scheduleCommunitySourceBootstrap(library, cookie: sessionCookie) { [weak controller = self] succeeded in
                Task { @MainActor [weak controller] in
                    guard let controller, controller.signedIn, controller.library == library else { return }
                    let state = succeeded ? "ready" : "deferred"
                    _ = try? await controller.webView.evaluateJavaScript("window.__sumidokuCommunityStatus='\(state)';window.dispatchEvent(new CustomEvent('sumidoku:source-lists',{detail:'\(state)'}))")
                }
            }
        }
    }

    func openLibrary() { if let library = library { NSWorkspace.shared.open(library.root) } }
    func openBackups() { if let library = library { NSWorkspace.shared.open(library.backups) } }
    func showSourceLists() {
        nativePanel = nil
        guard signedIn else { controlError = "Sign in to manage Source Lists."; return }
        navigate("/browse?view=lists")
    }

    func showBackupRestore() {
        nativePanel = nil
        guard signedIn else { controlError = "Sign in before opening Backup and Restore."; return }
        // Keep the upstream backup UI, its preview and section selectors.
        navigate("/settings?section=backups")
        NSApp.activate(ignoringOtherApps: true)
    }

    func control(_ action: String) async {
        guard operation == nil, library != nil else { return }
        controlError = nil
        sessionGeneration += 1
        operation = action == "restart" ? "Restarting server…" : "Starting server…"
        defer { operation = nil }
        do { try await WebSessionQuiescer.suspend(webView) }
        catch { controlError = error.localizedDescription; return }
        guard let helper = Bundle.main.url(forResource: "service", withExtension: "sh") else {
            message = "The bundled server control helper is missing. Reinstall Sumidoku.app."
            return
        }
        let result: (Int32, String) = await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path, action]+InstallationContext.serviceArguments
            process.environment = ["HOME": InstallationContext.home.path,
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                try? pipe.fileHandleForWriting.close()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: output, as: UTF8.self))
            } catch { return (-1, error.localizedDescription) }
        }.value
        operation = nil
        await check(reload: true)
        if result.0 != 0 {
            let detail = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
            controlError = detail.isEmpty ? "Server control failed. Check the existing LaunchAgent and server logs." : detail
        }
    }

    func openFolder(_ relativePath: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        NSWorkspace.shared.open(folder)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        available = false
        message = "The interface could not be loaded. Check the local server and try again."
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        available = false
        message = "The interface connection was interrupted. Check the local server and try again."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { await check(reload: true) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if NavigationPolicy.isLocal(url, port: manager.api.base.port ?? 3000) || ["about", "blob"].contains(url.scheme ?? "") {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.lowercased().contains("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if NavigationPolicy.isLocal(url, port: manager.api.base.port ?? 3000) { webView.load(URLRequest(url: url)) }
            else if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { result in completionHandler(result == .OK ? panel.url : nil) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        message = "Export could not be saved: \(error.localizedDescription)"
        let alert = NSAlert()
        alert.messageText = "Export could not be saved"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

struct EmbeddedInterface: NSViewRepresentable {
    let controller: ServerController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct MainWindow: View {
    @ObservedObject var controller: ServerController
    let delegate: AppDelegate
    @ObservedObject var updates: AppUpdates
    @Environment(\.openWindow) private var openWindow
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    @MainActor
    private func configureInstallation() async {
        guard let library = controller.library else { updates.installer = nil; await updates.refreshInstallation(); return }
        let manager = controller.manager
        updates.installer = NativeUpdateInstaller(paths:InstallationPaths(application:Bundle.main.bundleURL,config:library.config,backups:library.backups,runtime:manager.binary,agent:manager.agent,runner:manager.runner,port:manager.api.base.port ?? 3000),support:manager.support,beforeHandoff:{ recovering in
            guard controller.operation == nil, recovering || controller.signedIn else { throw UpdateFailure("Finish current maintenance and sign in before updating.") }
            let session = UpdateSession(cookie:await controller.cookieHeader(),username:controller.username)
            controller.operation = "Preparing application update"
            do { try await WebSessionQuiescer.suspend(controller.webView) }
            catch { controller.operation = nil; throw error }
            return session
        },handoffFailed:{
            controller.operation = nil
            await controller.check(reload:true)
        })
        await updates.refreshInstallation()
    }

    var body: some View {
        ZStack {
            if controller.library == nil || (controller.available && !controller.signedIn) {
                ScrollView {
                    WelcomeView(controller: controller).frame(maxWidth: .infinity, minHeight: 540)
                }
            } else if controller.available && controller.signedIn { DesktopShell(controller: controller, updates: updates) }
            else {
                VStack(spacing: 16) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName)!)
                        .resizable().frame(width: 72, height: 72)
                    Text(controller.checking ? "Connecting to Sumidoku…" : "Sumidoku server is unavailable")
                        .font(.title2).fontWeight(.semibold)
                    Text(controller.controlError ?? (controller.message.isEmpty ? "Checking the local background server." : controller.message))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if controller.checking || controller.operation != nil {
                        ProgressView().controlSize(.small)
                        if let operation = controller.operation { Text(operation).foregroundStyle(.secondary) }
                    } else {
                        HStack {
                            Button("Start Server") { Task { await controller.control("start") } }
                                .keyboardShortcut(.defaultAction)
                            Button("Check Again") { Task { await controller.check() } }
                        }
                    }
                }.padding(40).frame(maxWidth: 560)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .task {
            delegate.reopen = { openWindow(id: "main") }
            controller.showUpdates = { openWindow(id: "application-updates") }
            controller.checkAppUpdates = { updates.check() }
            if let library = controller.library { updates.loadInstalledHistory(library.backups) }
            updates.checkIfDue()
            #if COMMUNITY_E2E
            if let root = ReleaseIdentity.fixtureRoot,
               let data = try? Data(contentsOf:URL(fileURLWithPath:root).appendingPathComponent("session.json")),
               let credentials = try? JSONDecoder().decode([String:String].self,from:data) {
                controller.username = credentials["username"] ?? ""
                let api = controller.manager.api
                if let library = controller.library,
                   let login = try? await Task.detached(operation: { try api.login(username:credentials["username"] ?? "",password:credentials["password"] ?? "") }).value {
                    await controller.accept(login,library:library)
                }
            }
            #endif
            await controller.check()
            await configureInstallation()
            #if COMMUNITY_E2E
            CommunityEndToEnd.attach(controller:controller,updates:updates)
            #endif
            if let index = CommandLine.arguments.firstIndex(of:"--complete-update"), CommandLine.arguments.count > index+1,
               let library = controller.library, controller.signedIn {
                let url = URL(fileURLWithPath:CommandLine.arguments[index+1]).standardizedFileURL
                if url.path.hasPrefix(library.backups.standardizedFileURL.resolvingSymlinksInPath().path+"/ApplicationUpdate-"), url.lastPathComponent == "update-journal.json",
                   url.resolvingSymlinksInPath().path == url.path,
                   let data = try? Data(contentsOf:url), let journal = try? JSONDecoder().decode(PairedJournal.self,from:data),
                   journal.phase == "artifacts-replaced", journal.paths.application.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path,
                   journal.paths.config.standardizedFileURL.path == library.config.standardizedFileURL.path,
                   journal.version == updates.installed {
                    for _ in 0..<100 {
                        if !controller.webView.isLoading, (try? await controller.webView.evaluateJavaScript("document.querySelector('#root')?.childElementCount > 0")) as? Bool == true {
                            let ack: [String:Any] = ["version":updates.installed,"signedIn":true]
                            if let bytes = try? JSONSerialization.data(withJSONObject:ack) {
                                let file = url.deletingLastPathComponent().appendingPathComponent("relaunch-verified.json")
                                try? bytes.write(to:file,options:.atomic)
                                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                                // The helper commits "verified" only after this acknowledgement.
                                // Refresh once it commits, so Restore Stable is immediately usable.
                                for _ in 0..<100 {
                                    if let bytes = try? Data(contentsOf:url),
                                       let completed = try? JSONDecoder().decode(PairedJournal.self,from:bytes), completed.phase == "verified" {
                                        await updates.refreshInstallation()
                                        updates.loadInstalledHistory(library.backups)
                                        break
                                    }
                                    try? await Task.sleep(nanoseconds:200_000_000)
                                }
                            }
                            break
                        }
                        try? await Task.sleep(nanoseconds:200_000_000)
                    }
                }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--capture-window"), CommandLine.arguments.count > index + 1 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let routeIndex = CommandLine.arguments.firstIndex(of: "--capture-route"), CommandLine.arguments.count > routeIndex + 1 {
                    let route = CommandLine.arguments[routeIndex + 1]
                    if route == "native:updates" { controller.nativePanel = "updates" }
                    else if route == "native:server" { controller.nativePanel = "server" }
                    else { controller.navigate(route) }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let captureURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                var report: [String: Any] = ["configured": controller.library != nil, "serverAvailable": controller.available, "signedIn": controller.signedIn, "route": controller.route, "nativePanel": controller.nativePanel ?? "", "version": updates.installed, "captureSucceeded": false]
                if let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) {
                    do { try await OwnWindowCapture.save(window, webView: controller.signedIn && controller.nativePanel == nil ? controller.webView : nil, to: captureURL); report["captureSucceeded"] = true }
                    catch { fputs("Own-window capture failed: \(error.localizedDescription)\n", stderr) }
                }
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: captureURL.appendingPathExtension("status.json"), options: .atomic) }
            }
        }
        .onChange(of:controller.signedIn) { _ in Task { await configureInstallation() } }
        .onReceive(refresh) { _ in
            guard controller.operation == nil else { return }
            Task { await controller.check() }
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var controller: ServerController
    @State private var owner = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Sumidoku Library")
    @State private var recoveryConfirmation = false
    var creating: Bool { controller.onboarding == "create" }
    var recovering: Bool { controller.onboarding == "recover" }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.prompt = creating ? "Choose Library Folder" : "Connect to Library"
        panel.begin { if $0 == .OK, let url = panel.url { folder = url } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(nsImage: NSImage(named: NSImage.applicationIconName)!).resizable().frame(width: 80, height: 80)
                VStack(alignment: .leading) {
                    Text("Your next chapter.").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("Your manga library, on this Mac.").foregroundStyle(.secondary)
                }
            }
            if controller.onboarding == "welcome" {
                Text("Create a local library with an owner account you choose, or sign in to an existing library. This is a local server account, not an internet account.")
                HStack {
                    Button("Create New Library") { controller.onboarding = "create" }.keyboardShortcut(.defaultAction)
                    Button("Sign In") { controller.onboarding = "signin" }
                }
            } else {
                Text(recovering ? "Recover local owner access" : (creating ? "Create New Library" : "Sign In")).font(.title2).bold()
                if !recovering {
                    Text(creating ? "Choose a new empty folder. Existing library folders are never overwritten." : "Select the primary folder of an existing Sumidoku desktop library. Signing in reuses its database and settings.")
                    Text(folder.path).font(.callout).textSelection(.enabled)
                    Button(creating ? "Choose Storage Folder…" : "Choose Existing Library…", action: chooseFolder)
                }
                TextField("Username", text: $owner).textFieldStyle(.roundedBorder)
                SecureField(recovering ? "New password (at least 8 characters)" : "Password", text: $password).textFieldStyle(.roundedBorder)
                if creating || recovering { SecureField("Confirm password", text: $confirmation).textFieldStyle(.roundedBorder) }
                if creating {
                    Text("Server: database, settings, source packages, metadata and reading progress. Downloads: only chapters you explicitly download. Backups: daily snapshots. Temporary reader pages may be cached under Server; a cache is not an offline chapter download.").font(.callout).foregroundStyle(.secondary)
                    Text("Automatic chapter downloads and download-ahead start turned off. Saving a title stores metadata.").font(.callout)
                }
                if recovering {
                    Text("This Mac's owner can replace the local owner's credentials. The server will stop briefly and a private recovery snapshot will be kept in Backups. Your library is retained; no database is deleted.").font(.callout)
                    Toggle("I confirm that I want to replace this library's owner credentials", isOn: $recoveryConfirmation)
                }
                HStack {
                    Button("Back") { controller.onboarding = "welcome"; controller.controlError = nil; password = ""; confirmation = "" }
                    Button(recovering ? "Reset Owner Password" : (creating ? "Create Library" : "Sign In")) {
                        let secret = password, confirm = confirmation
                        password = ""; confirmation = ""
                        Task {
                            if recovering { await controller.passwordAction(current: "", new: secret, confirmation: confirm, owner: owner, recovery: true) }
                            else { await controller.authenticate(create: creating, root: controller.library?.root ?? folder, username: owner, password: secret, confirmation: confirm) }
                        }
                    }.keyboardShortcut(.defaultAction).disabled(recovering && !recoveryConfirmation)
                    if !creating && !recovering && controller.library != nil {
                        Button("Forgot Password…") { controller.onboarding = "recover" }
                    }
                }
            }
            if let error = controller.controlError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let operation = controller.operation { HStack { ProgressView().controlSize(.small); Text(operation) } }
        }
        .padding(40).frame(maxWidth: 620).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 24)).padding(28).tint(DesktopBrand.accent)
        .disabled(controller.operation != nil)
        .onAppear { if let root = controller.library?.root { folder = root } }
    }
}

struct ServerSettings: View {
    var embedded = false
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: ServerController
    var body: some View {
        Form {
            Section("Local server") {
                LabeledContent("Status", value: controller.operation ?? (controller.available ? "Running" : "Unavailable"))
                LabeledContent("Account", value: controller.signedIn ? controller.username : "Signed out")
                if let library = controller.library {
                    LabeledContent("Storage") { Text(library.root.path).textSelection(.enabled) }
                    HStack {
                        Button("Start Server") { Task { await controller.control("start") } }
                        Button("Restart Server") { Task { await controller.control("restart") } }
                    }
                    Button("Open Library Folder") { controller.openLibrary() }
                    Button("Open Backups") { controller.openBackups() }
                    Button("Open Logs") { controller.openFolder("Library/Logs/Sumidoku") }
                } else { Text("Create or connect to a library in the main window.") }
            }
            if controller.signedIn {
                Section("Owner account") {
                    Button("Accounts & Integrations…") { controller.navigate("/settings?section=accounts"); if !embedded { NSApp.keyWindow?.close(); openWindow(id: "main") } }
                    Button("Source Lists") { controller.showSourceLists(); if !embedded { NSApp.keyWindow?.close(); openWindow(id: "main") } }
                    Button("Backup and Restore…") { controller.showBackupRestore(); if !embedded { NSApp.keyWindow?.close(); openWindow(id: "main") } }
                    Button("Sign Out") { Task { await controller.signOut() } }
                    Text("Backup and Restore opens the existing server's Settings. Use its export, restore preview and section selectors. Restoring settings may change your download preferences; review them afterward.").font(.footnote)
                }
            }
            if let error = controller.controlError { Text(error).foregroundStyle(.red) }
            Text("Quitting or signing out leaves your library files, background server and scheduled backups in place.")
                .font(.footnote).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding().frame(width: 580)
            .disabled(controller.operation != nil)
    }
}


#if !NATIVE_UI_TESTS
@main
@MainActor
struct SumidokuDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = ServerController()
    @StateObject private var updates = AppUpdates()
    var body: some Scene {
        Window("Sumidoku", id: "main") {
            MainWindow(controller: controller, delegate: delegate, updates: updates)
        }
        .defaultSize(width: 1200, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { controller.showUpdates?(); updates.check() }
            }
            CommandMenu("Navigate") {
                Button("Library") { controller.navigate("/library") }.keyboardShortcut("1", modifiers: .command)
                Button("Sources") { controller.navigate("/browse") }.keyboardShortcut("2", modifiers: .command)
                Button("History") { controller.navigate("/history") }.keyboardShortcut("3", modifiers: .command)
                Button("Find…") { controller.webView.evaluateJavaScript("document.querySelector(\"input[type=search]\")?.focus()") }.keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Server") {
                Button("Reload Interface") { Task { await controller.check(reload: true) } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Start Server") { Task { await controller.control("start") } }
                Button("Restart Server") { Task { await controller.control("restart") } }
                Divider()
                Button("Open Library Folder") { controller.openLibrary() }
                Button("Open Logs") { controller.openFolder("Library/Logs/Sumidoku") }
            }
        }
        Window("Application Updates", id: "application-updates") { ApplicationUpdatesView(updates: updates) }
        Settings { NativePreferences(controller: controller, updates: updates) }
    }
}

#endif
