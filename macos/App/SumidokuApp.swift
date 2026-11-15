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
    let webView: WKWebView
    private var probing = false
    private var loaded = false
    private let session: URLSession

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let network = URLSessionConfiguration.ephemeral
        network.timeoutIntervalForRequest = 2
        network.timeoutIntervalForResource = 3
        session = URLSession(configuration: network)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func check(reload: Bool = false) async {
        guard !probing else { return }
        probing = true
        defer { probing = false; checking = false }
        do {
            let url = Self.address.appendingPathComponent("health")
            let (data, response) = try await session.data(from: url)
            let document = try JSONSerialization.jsonObject(with: data) as? [String: String]
            guard (response as? HTTPURLResponse)?.statusCode == 200, document?["status"] == "ok" else {
                throw URLError(.badServerResponse)
            }
            let recovered = !available
            available = true
            message = ""
            if !loaded || recovered || reload {
                loaded = true
                if webView.url != nil { webView.reload() }
                else { webView.load(URLRequest(url: Self.address)) }
            }
        } catch {
            available = false
            message = "The existing local server is not responding at 127.0.0.1:3000."
        }
    }

    func control(_ action: String) async {
        guard operation == nil else { return }
        controlError = nil
        operation = action == "restart" ? "Restarting server…" : "Starting server…"
        defer { operation = nil }
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
            if controller.available { EmbeddedInterface(controller: controller) }
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

struct ServerSettings: View {
    @ObservedObject var controller: ServerController
    var body: some View {
        Form {
            Section("Local server") {
                LabeledContent("Address", value: "127.0.0.1:3000")
                LabeledContent("Status", value: controller.operation ?? (controller.available ? "Running" : "Unavailable"))
                HStack {
                    Button("Check Status") { Task { await controller.check() } }
                    Button("Start Server") { Task { await controller.control("start") } }
                    Button("Restart Server") { Task { await controller.control("restart") } }
                }.disabled(controller.operation != nil)
                if let error = controller.controlError { Text(error).foregroundStyle(.secondary) }
                else if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.secondary) }
            }
            Section("Files") {
                Button("Open Data Folder") { controller.openFolder("Library/Application Support/Sumidoku") }
                Button("Open Logs") { controller.openFolder("Library/Logs/Sumidoku") }
                Button("Open Backups") { controller.openFolder("Documents/Sumidoku Backups") }
            }
            Text("Quitting this app leaves the background server and scheduled backups running.")
                .font(.footnote).foregroundStyle(.secondary)
        }.formStyle(.grouped).padding().frame(width: 520)
    }
}

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
                Button("Open Data Folder") { controller.openFolder("Library/Application Support/Sumidoku") }
                Button("Open Logs") { controller.openFolder("Library/Logs/Sumidoku") }
            }
        }
        Settings { ServerSettings(controller: controller) }
    }
}
