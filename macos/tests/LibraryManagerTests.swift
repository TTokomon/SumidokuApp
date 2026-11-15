import Foundation
import SQLite3
import AppKit
import WebKit

final class DisposableService: LibraryService {
    let binary: URL
    var process: Process?
    var config: URL?
    var failStart = false
    var failAfterStart = false
    var starts = 0
    init(binary: URL) { self.binary = binary }
    func loaded() -> Bool { process?.isRunning == true }
    func start(plist: URL) throws {
        if failStart { throw LibraryFailure(text: "Injected startup failure") }
        guard !loaded() else { return }
        let doc = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        let args = doc["ProgramArguments"] as! [String]
        config = URL(fileURLWithPath: args[2])
        try launch()
        if failAfterStart {
            for _ in 0..<100 {
                if (try? LocalAPI(port: 3302).request("health").json["status"] as? String) == "ok" { throw LibraryFailure(text: "Injected failure after database creation and readiness") }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw LibraryFailure(text: "Injected failure after launch")
        }
    }
    func launch() throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--config-dir", config!.path]
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": config!.path]
        p.currentDirectoryURL = config
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); process = p; starts += 1
    }
    func stop() throws {
        guard let process = process, process.isRunning else { self.process = nil; return }
        kill(process.processIdentifier, SIGINT)
        for _ in 0..<100 {
            if !process.isRunning { self.process = nil; return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LibraryFailure(text: "Disposable server did not stop")
    }
    func restart() throws { try stop(); try launch() }
    deinit { try? stop() }
}

final class DisposableLaunchAgent: LibraryService {
    let label = "app.sumidoku.onboarding-test-" + UUID().uuidString.lowercased()
    let plist: URL
    var starts = 0
    var failStart = false
    var failAfterStart = false
    var target: String { "gui/\(getuid())/\(label)" }
    init(directory: URL) { plist = directory.appendingPathComponent("TestLaunchAgent.plist") }
    func loaded() -> Bool { (try? LaunchAgentService.run("/bin/launchctl", ["print", target])) == 0 }
    func start(plist source: URL) throws {
        if failStart { throw LibraryFailure(text: "Injected startup failure") }
        guard !loaded() else { return }
        var doc = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as! [String: Any]
        doc["Label"] = label; doc["ThrottleInterval"] = 1
        doc["EnvironmentVariables"] = ["HOME": plist.deletingLastPathComponent().path]
        try PropertyListSerialization.data(fromPropertyList: doc, format: .xml, options: 0).write(to: plist)
        guard try LaunchAgentService.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path]) == 0 else { throw LibraryFailure(text: "Disposable LaunchAgent failed to load") }
        starts += 1
        if failAfterStart {
            for _ in 0..<100 {
                if (try? LocalAPI(port: 3302).request("health").json["status"] as? String) == "ok" { throw LibraryFailure(text: "Injected failure after database creation and readiness") }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw LibraryFailure(text: "Injected failure after launch")
        }
    }
    func stop() throws {
        guard loaded() else { return }
        let processes = pids()
        var unloaded = false
        for _ in 0..<50 {
            if (try LaunchAgentService.run("/bin/launchctl", ["bootout", target])) == 0 || !loaded() { unloaded = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard unloaded else { throw LibraryFailure(text: "Disposable LaunchAgent failed to unload") }
        for _ in 0..<200 {
            if processes.allSatisfy({ kill($0, 0) != 0 }) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LibraryFailure(text: "Disposable LaunchAgent runner is still exiting")
    }
    func pids() -> [Int32] {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try? process.run(); try? pipe.fileHandleForWriting.close()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            return parts.count == 3 && parts[0] == "pid" && parts[1] == "=" ? Int32(parts[2]) : nil
        }
    }
    func restart() throws {
        let old = pids()
        guard try LaunchAgentService.run("/bin/launchctl", ["kill", "SIGTERM", target]) == 0 else { throw LibraryFailure(text: "Disposable restart failed") }
        for _ in 0..<200 {
            let new = pids()
            if !new.isEmpty && new != old { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw LibraryFailure(text: "Disposable restart timed out")
    }
    deinit { try? stop() }
}

@MainActor
final class WebSessionProbe: NSObject, WKNavigationDelegate {
    var completion: CheckedContinuation<Void, Error>?
    func load(_ view: WKWebView, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            view.navigationDelegate = self
            view.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let pending = self.completion { self.completion = nil; pending.resume(throwing: LibraryFailure(text: "WKWebView load timed out")) }
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion?.resume(); completion = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completion?.resume(throwing: error); completion = nil }
    func identity(_ view: WKWebView) async throws -> [String: Any] {
        let value = try await view.callAsyncJavaScript("return await (await fetch('/api/v1/auth/status')).json()", arguments: [:], in: nil, contentWorld: .page)
        return value as? [String: Any] ?? [:]
    }
}

@main
struct LibraryManagerTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw LibraryFailure(text: "FAIL: \(name)") }
        assertions += 1
        print("PASS: \(name)")
    }
    @discardableResult
    static func rejects(_ name: String, _ body: () throws -> Void) throws -> String {
        do { try body() } catch { assertions += 1; print("PASS: \(name)"); return error.localizedDescription }
        throw LibraryFailure(text: "FAIL: \(name)")
    }
    static func sql(_ config: URL, _ statement: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open(config.appendingPathComponent("sumidoku.db").path, &db) == SQLITE_OK else { throw LibraryFailure(text: "Fixture database could not open") }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, statement, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "SQL failure"
            sqlite3_free(error); throw LibraryFailure(text: detail)
        }
        var query: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT count(*) FROM chapter_user WHERE last_page_read = 7", -1, &query, nil)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { return "0" }
        return String(sqlite3_column_int(query, 0))
    }
    static func main() async {
        do { try await run() }
        catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
    }
    @MainActor
    static func run() async throws {
        setbuf(stdout, nil)
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sumidoku-onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let direct = DisposableService(binary: binary)
        let agentDriver = DisposableLaunchAgent(directory: temporary)
        let useLaunchAgent = CommandLine.arguments.contains("--launchagent")
        let service: LibraryService = useLaunchAgent ? agentDriver : direct
        defer { try? service.stop(); try? FileManager.default.removeItem(at: temporary) }
        let runner = temporary.appendingPathComponent("runner.sh")
        let sourceRunner = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.copyItem(at: sourceRunner, to: runner)
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("sumidoku-server"), withDestinationURL: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        let home = temporary.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let manager = LibraryManager(home: home, binary: binary, runner: runner, service: service, port: 3302)
        try expect(try manager.current() == nil, "clean first run has no configured library")
        try rejects("mismatched passwords rejected") { try LibraryManager.validateOwner("fixture-owner", "disposable-password", "different") }
        let root = temporary.appendingPathComponent("Custom Library Ω")
        let password = UUID().uuidString + "'''\"\\\n"
        let result = try manager.create(root: root, username: "fixture-owner", password: password, confirmation: password)
        let library = result.0
        var cookie = LocalAPI.cookieHeader(result.1.cookies)
        let activeConfig = try String(contentsOf: library.config.appendingPathComponent("config.toml"), encoding: .utf8)
        try expect(!activeConfig.contains("[auth]") && !activeConfig.contains("password = "), "plaintext seed removed after owner creation")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = WKWebsiteDataStore.nonPersistent()
        for cookie in result.1.cookies { await store.httpCookieStore.setCookie(cookie) }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: configuration)
        let probe = WebSessionProbe()
        try await probe.load(view, url: manager.api.base)
        let identity = try await probe.identity(view)
        try expect(identity["username"] as? String == "fixture-owner", "native login cookie transferred to actual WKWebView")

        try expect(try manager.current() == library, "custom directory persisted across manager recreation")
        try expect(FileManager.default.fileExists(atPath: library.config.appendingPathComponent("sumidoku.db").path), "database created only inside chosen Server folder")
        try expect(!String(contentsOf: manager.descriptor, encoding: .utf8).contains(password), "descriptor contains no password")
        let defaults = try manager.api.request("api/v1/settings", cookie: cookie).json["download"] as! [String: Any]
        try expect(defaults["downloadAhead"] as? Bool == false && defaults["autoDownloadNewChapters"] as? Bool == false && defaults["autoDownloadLimit"] as? Int == 0, "automatic downloads and download-ahead disabled")
        try await WebSessionQuiescer.suspend(view)
        _ = try manager.api.request("api/v1/auth/logout", method: "POST", cookie: cookie)
        let loggedOut = try manager.api.request("api/v1/auth/status", cookie: cookie)
        try expect(loggedOut.json["username"] == nil, "sign out revokes session without deleting database")
        for cookie in await store.httpCookieStore.allCookies() { await store.httpCookieStore.deleteCookie(cookie) }
        let signedOutWeb = try manager.api.request("api/v1/auth/status").json
        let remainingCookies = await store.httpCookieStore.allCookies()
        try expect(signedOutWeb["username"] == nil && remainingCookies.isEmpty, "native sign-out clears WebKit cookie and authenticated web access")

        try await WebSessionQuiescer.suspend(view)
        try expect(view.url?.absoluteString == "about:blank", "native document teardown closes live event stream before server stop")
        let signedIn = try manager.connect(root: root, username: "fixture-owner", password: password)
        cookie = LocalAPI.cookieHeader(signedIn.1.cookies)
        try expect((useLaunchAgent ? agentDriver.starts : direct.starts) == 1, "sign in reuses running server")
        try rejects("wrong credentials rejected clearly") { _ = try manager.api.login(username: "fixture-owner", password: "wrong") }
        let anotherRoot = temporary.appendingPathComponent("Must Not Exist")
        try rejects("configured library blocks duplicate creation") { _ = try manager.create(root: anotherRoot, username: "other", password: password, confirmation: password) }
        try expect(!FileManager.default.fileExists(atPath: anotherRoot.path), "duplicate attempt creates no directory")
        try service.stop()
        let fixtureSQL = """
        INSERT INTO manga (source_id,key,title) VALUES (1,'fixture-manga','Fixture title');
        INSERT INTO manga_user (manga_id,user_id,in_library) VALUES ((SELECT id FROM manga LIMIT 1),1,1);
        INSERT INTO chapter (manga_id,key,title) VALUES ((SELECT id FROM manga LIMIT 1),'fixture-chapter','Chapter');
        INSERT INTO chapter_user (chapter_id,user_id,last_page_read) VALUES ((SELECT id FROM chapter LIMIT 1),1,7);
        INSERT INTO category (user_id,name) VALUES (1,'Fixture category');
        """
        _ = try sql(library.config, fixtureSQL)
        try FileManager.default.createDirectory(at: library.config.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let sourceMarker = library.config.appendingPathComponent("sources/fixture-marker.txt")
        try Data("source-preservation-fixture".utf8).write(to: sourceMarker)
        try service.start(plist: manager.agent); try manager.waitReady()
        cookie = LocalAPI.cookieHeader(try manager.api.login(username: "fixture-owner", password: password).cookies)
        let reopened = LibraryManager(home: home, binary: binary, runner: runner, service: service, port: 3302)
        try expect(try reopened.current() == library, "app relaunch reads same folder descriptor")
        let web = try manager.api.request("")
        try expect(web.response.statusCode == 200 && !web.data.isEmpty, "existing web interface opens")
        let newPassword = UUID().uuidString
        let changed = try manager.changePassword(library: library, current: password, new: newPassword, confirmation: newPassword, cookie: cookie)
        cookie = LocalAPI.cookieHeader(changed.cookies)
        try service.restart(); try manager.waitReady()
        _ = try manager.api.login(username: "fixture-owner", password: newPassword)
        try rejects("old password remains invalid after restart") { _ = try manager.api.login(username: "fixture-owner", password: password) }
        try expect(try sql(library.config, "SELECT 1") == "1", "reading progress survives account change and service restart")
        try expect(FileManager.default.fileExists(atPath: sourceMarker.path), "source files remain in chosen folder")
        let recoveredPassword = UUID().uuidString
        _ = try manager.recoverPassword(library: library, username: "recovered-owner", new: recoveredPassword, confirmation: recoveredPassword)
        try service.stop(); try service.start(plist: manager.agent); try manager.waitReady()
        _ = try manager.api.login(username: "recovered-owner", password: recoveredPassword)
        try expect(try sql(library.config, "SELECT 1") == "1", "explicit local recovery preserves progress after unload/reload")
        let finalCookie = LocalAPI.cookieHeader(try manager.api.login(username: "recovered-owner", password: recoveredPassword).cookies)
        let exported = try manager.api.request("api/v1/backups/document", cookie: finalCookie).json
        try expect((exported["categories"] as? [[String: Any]])?.contains { $0["name"] as? String == "Fixture category" } == true && (exported["library"] as? [[String: Any]])?.count == 1, "categories and saved library survive recovery")
        try expect(try FileManager.default.contentsOfDirectory(atPath: library.backups.path).contains { $0.hasPrefix("Recovery-") }, "cold recovery snapshots retained")
        try service.stop()
        // Removing a descriptor simulates reconnect, not database replacement.
        try FileManager.default.removeItem(at: manager.descriptor)
        let sentinel = try Data(contentsOf: library.config.appendingPathComponent("sumidoku.db"))
        try FileManager.default.removeItem(at: manager.agent)
        try rejects("existing library directory never overwritten") { _ = try manager.create(root: root, username: "other", password: password, confirmation: password) }
        try expect(try Data(contentsOf: library.config.appendingPathComponent("sumidoku.db")) == sentinel, "rejected setup leaves database byte-identical")
        let reconnected = try manager.connect(root: root, username: "recovered-owner", password: recoveredPassword)
        try expect(reconnected.0 == library && (try sql(library.config, "SELECT 1")) == "1", "existing library reconnects without losing progress")
        try service.stop()
        try FileManager.default.removeItem(at: manager.descriptor)
        try FileManager.default.removeItem(at: manager.agent)
        direct.failStart = true; agentDriver.failStart = true
        let failedRoot = temporary.appendingPathComponent("Failed Setup")
        try rejects("injected startup failure reported") { _ = try manager.create(root: failedRoot, username: "owner", password: password, confirmation: password) }
        try expect(!FileManager.default.fileExists(atPath: failedRoot.path) && !FileManager.default.fileExists(atPath: manager.agent.path) && !FileManager.default.fileExists(atPath: manager.descriptor.path), "failed setup leaves no agent, partial DB or descriptor")
        try expect(try sql(library.config, "SELECT 1") == "1", "failed new setup leaves existing library intact")
        direct.failStart = false; agentDriver.failStart = false
        direct.failAfterStart = true; agentDriver.failAfterStart = true
        let rollbackError = try rejects("failure after real database creation reported") { _ = try manager.create(root: failedRoot, username: "owner", password: password, confirmation: password) }
        try expect(rollbackError == "Injected failure after database creation and readiness", "rollback test reached actual server readiness before failure")
        try expect(!service.loaded() && !FileManager.default.fileExists(atPath: failedRoot.path) && !FileManager.default.fileExists(atPath: manager.agent.path), "post-start rollback stops service and removes only its partial database")
        print("PASS: \(assertions) onboarding lifecycle assertions; all data disposable; driver: \(useLaunchAgent ? "temporary launchd job" : "direct subprocess").")
    }
}
