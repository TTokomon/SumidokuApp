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
final class ServerController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let address = URL(string: "http://127.0.0.1:3000")!
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
    let webView: WKWebView
    private var sessionGeneration = 0
    private var probing = false
    private var loaded = false
    private let session: URLSession

    init(manager injectedManager: LibraryManager? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let network = URLSessionConfiguration.ephemeral
        network.timeoutIntervalForRequest = 2
        network.timeoutIntervalForResource = 3
        session = URLSession(configuration: network)
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sumidoku/bin")
        let helper = Bundle.main.url(forResource: "service", withExtension: "sh")!
        manager = injectedManager ?? LibraryManager(binary: support.appendingPathComponent("sumidoku-server"),
                                 runner: support.appendingPathComponent("run-server.sh"),
                                 service: LaunchAgentService(helper: helper))
        super.init()
        do { library = try manager.current(); if library != nil { onboarding = "signin" } }
        catch { controlError = error.localizedDescription }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
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
        webView.load(URLRequest(url: Self.address))
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
            if signedIn && (!loaded || reload) {
                loaded = true
                webView.load(URLRequest(url: Self.address))
            }
            if !signedIn { loaded = false; onboarding = "signin" }
        } catch {
            guard generation == sessionGeneration, operation == nil else { return }
            available = false
            message = "The local server is unavailable. Start it to open your library."
        }
    }

    func openLibrary() { if let library = library { NSWorkspace.shared.open(library.root) } }
    func openBackups() { if let library = library { NSWorkspace.shared.open(library.backups) } }
    func showBackupRestore() {
        guard signedIn else { controlError = "Sign in before opening Backup and Restore."; return }
        // Keep the upstream backup UI, its preview and section selectors.
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:3000/settings?section=backups")!))
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
            process.arguments = [helper.path, action]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
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
        if NavigationPolicy.isLocal(url) || ["about", "blob"].contains(url.scheme ?? "") {
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
            if NavigationPolicy.isLocal(url) { webView.load(URLRequest(url: url)) }
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
    @Environment(\.openWindow) private var openWindow
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if controller.library == nil || (controller.available && !controller.signedIn) {
                ScrollView {
                    WelcomeView(controller: controller).frame(maxWidth: .infinity, minHeight: 540)
                }
            } else if controller.available && controller.signedIn { EmbeddedInterface(controller: controller) }
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
            await controller.check()
        }
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
                Image(nsImage: NSImage(named: NSImage.applicationIconName)!).resizable().frame(width: 60, height: 60)
                VStack(alignment: .leading) {
                    Text("Welcome to Sumidoku").font(.largeTitle).bold()
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
        .padding(40).frame(maxWidth: 640)
        .disabled(controller.operation != nil)
        .onAppear { if let root = controller.library?.root { folder = root } }
    }
}

struct ServerSettings: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: ServerController
    @State private var changingPassword = false
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
                    Button("Change Password…") { changingPassword = true }
                    Button("Backup and Restore…") { controller.showBackupRestore(); NSApp.keyWindow?.close(); openWindow(id: "main") }
                    Button("Sign Out") { Task { await controller.signOut() } }
                    Text("Backup and Restore opens the existing server's Settings. Use its export, restore preview and section selectors. Restoring settings may change your download preferences; review them afterward.").font(.footnote)
                }
            }
            if let error = controller.controlError { Text(error).foregroundStyle(.red) }
            Text("Quitting or signing out leaves your library files, background server and scheduled backups in place.")
                .font(.footnote).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding().frame(width: 580)
            .disabled(controller.operation != nil)
            .sheet(isPresented: $changingPassword) { PasswordSheet(controller: controller, presented: $changingPassword) }
    }
}

struct PasswordSheet: View {
    @ObservedObject var controller: ServerController
    @Binding var presented: Bool
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Password").font(.title2).bold()
            Text("The server will stop briefly to save a recovery snapshot. Your new password will stay effective after restart.")
            SecureField("Current password", text: $current)
            SecureField("New password (at least 8 characters)", text: $new)
            SecureField("Confirm new password", text: $confirmation)
            if let error = controller.controlError { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { current = ""; new = ""; confirmation = ""; presented = false }
                Button("Change Password") {
                    let old = current, secret = new, confirm = confirmation
                    current = ""; new = ""; confirmation = ""
                    Task {
                        await controller.passwordAction(current: old, new: secret, confirmation: confirm, owner: controller.username, recovery: false)
                        if controller.controlError == nil { presented = false }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 430).disabled(controller.operation != nil)
    }
}

#if !NATIVE_UI_TESTS
@main
@MainActor
struct SumidokuDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = ServerController()
    var body: some Scene {
        Window("Sumidoku", id: "main") {
            MainWindow(controller: controller, delegate: delegate)
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
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
        Settings { ServerSettings(controller: controller) }
    }
}

#endif
