import Foundation
import Darwin

struct LibraryFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

struct LocalLibrary: Codable, Equatable {
    let root: URL
    let config: URL
    let downloads: URL
    let backups: URL
    static func == (left: Self, right: Self) -> Bool {
        zip([left.root, left.config, left.downloads, left.backups], [right.root, right.config, right.downloads, right.backups]).allSatisfy {
            $0.standardizedFileURL.resolvingSymlinksInPath().path == $1.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }
}

struct APIReply {
    let data: Data
    let response: HTTPURLResponse
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    var cookies: [HTTPCookie] {
        HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields.reduce(into: [String: String]()) {
            if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value }
        }, for: response.url!)
    }
}

// Synchronous networking is confined to background tasks, never the AppKit thread.
final class LocalAPI: @unchecked Sendable {
    let base: URL
    let session: URLSession
    init(port: Int = 3000) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    func request(_ route: String, method: String = "GET", body: [String: Any]? = nil,
                 cookie: String? = nil) throws -> APIReply {
        var request = URLRequest(url: base.appendingPathComponent(route))
        request.httpMethod = method
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var result: Result<APIReply, Error> = .failure(LibraryFailure(text: "The local server is unavailable."))
        let task = session.dataTask(with: request) { data, response, error in
            lock.lock(); defer { lock.unlock(); done.signal() }
            if let response = response as? HTTPURLResponse {
                result = .success(APIReply(data: data ?? Data(), response: response))
            } else { result = .failure(error ?? URLError(.cannotConnectToHost)) }
        }
        task.resume()
        guard done.wait(timeout: .now() + 12) == .success else { task.cancel(); throw LibraryFailure(text: "The local server timed out.") }
        lock.lock(); defer { lock.unlock() }
        let reply: APIReply
        do { reply = try result.get() }
        catch { throw LibraryFailure(text: "The local server is unavailable. Start it or check its logs.") }
        guard (200..<300).contains(reply.response.statusCode) else {
            if reply.response.statusCode == 401 { throw LibraryFailure(text: "Incorrect username or password, or your session has expired.") }
            if reply.response.statusCode == 429 { throw LibraryFailure(text: "Too many sign-in attempts. Wait a moment and try again.") }
            throw LibraryFailure(text: "The server could not complete this action (HTTP \(reply.response.statusCode)).")
        }
        return reply
    }
    func login(username: String, password: String) throws -> APIReply {
        try request("api/v1/auth/login", method: "POST", body: ["username": username, "password": password])
    }
    static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
    }
    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

protocol LibraryService: AnyObject {
    func loaded() -> Bool
    func start(plist: URL) throws
    func stop() throws
    func restart() throws
}

final class LaunchAgentService: LibraryService {
    let helper: URL
    init(helper: URL) { self.helper = helper }
    func loaded() -> Bool { (try? Self.run("/bin/launchctl", ["print", "gui/\(getuid())/app.sumidoku.server"])) == 0 }
    func start(plist: URL) throws { try action("start") }
    func stop() throws { try action("stop") }
    func restart() throws { try action("restart") }
    private func action(_ action: String) throws {
        guard try Self.run("/bin/bash", [helper.path, action]) == 0 else {
            throw LibraryFailure(text: "Server control failed. Your files are preserved; check the server logs.")
        }
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }
}

// No password or session token is written to the descriptor or UserDefaults.
final class LibraryManager: @unchecked Sendable {
    let home: URL
    let support: URL
    let descriptor: URL
    let agent: URL
    let binary: URL
    let runner: URL
    let service: LibraryService
    let api: LocalAPI
    let files = FileManager.default
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, binary: URL, runner: URL,
         service: LibraryService, port: Int = 3000) {
        self.home = home
        support = home.appendingPathComponent("Library/Application Support/Sumidoku")
        descriptor = support.appendingPathComponent("desktop-library.json")
        agent = home.appendingPathComponent("Library/LaunchAgents/app.sumidoku.server.plist")
        self.binary = binary; self.runner = runner; self.service = service; api = LocalAPI(port: port)
    }
    func current() throws -> LocalLibrary? {
        guard files.fileExists(atPath: descriptor.path) else {
            if files.fileExists(atPath: support.appendingPathComponent("config.toml").path) {
                return try existingLibrary(root: support)
            }
            return nil
        }
        do {
            let library = try JSONDecoder().decode(LocalLibrary.self, from: Data(contentsOf: descriptor))
            try validateExisting(library)
            return library
        } catch { throw LibraryFailure(text: "The saved library cannot be opened. Reconnect its folder; no files have been replaced.") }
    }
    static func validateOwner(_ username: String, _ password: String, _ confirmation: String) throws {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              username == username.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.contains("\n") else { throw LibraryFailure(text: "Choose a nonempty username without leading or trailing spaces.") }
        guard password.count >= 8 else { throw LibraryFailure(text: "Use a password with at least 8 characters.") }
        guard password == confirmation else { throw LibraryFailure(text: "The passwords do not match.") }
    }
    func privateDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    // Installing a source LIST is not installing source packages or manga chapters.
    // A private marker lives with the library, surviving app updates and preventing
    // deliberate removal of the list from being undone on a later sign-in.
    private static let communitySourceIndex = "https://aidoku-community.github.io/sources/index.min.json"

    private func ensureCommunitySourceList(_ library: LocalLibrary, cookie: String) throws {
        let marker = library.config.appendingPathComponent(".aidoku-community-list-initialized")
        guard !files.fileExists(atPath: marker.path) else { return }
        let reply = try api.request("api/v1/source-repos", cookie: cookie)
        guard let entries = try JSONSerialization.jsonObject(with: reply.data) as? [[String: Any]] else {
            throw LibraryFailure(text: "The source-list response was invalid; the existing library is unchanged.")
        }
        let subscribed = entries.contains { entry in
            guard let raw = entry["url"] as? String, let url = URL(string: raw),
                  let host = url.host?.lowercased() else { return false }
            return host == "aidoku-community.github.io"
                && (url.path == "/sources/index.min.json" || url.path == "/sources/index.json")
        }
        if !subscribed {
            _ = try api.request("api/v1/source-repos", method: "POST",
                                body: ["url": Self.communitySourceIndex, "name": "Aidoku Community"],
                                cookie: cookie)
        }
        // Mark only after the list exists. If offline, retry at the next
        // authenticated connection instead of blocking owner creation.
        try privateWrite(Data("subscribed once; removal is respected\n".utf8), to: marker)
    }

    private func scheduleCommunitySourceBootstrap(_ library: LocalLibrary, cookies: [HTTPCookie]) {
        let cookie = LocalAPI.cookieHeader(cookies)
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                try ensureCommunitySourceList(library, cookie: cookie)
            } catch {
                // The source-list request can fail offline. The library remains
                // usable; no marker is written, so a later sign-in can retry.
                NSLog("Default community source-list setup deferred: %@", error.localizedDescription)
            }
        }
    }

    static func quote(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }
    func baseConfig(_ library: LocalLibrary) -> String {
        """
        addr = "127.0.0.1:\(api.base.port!)"
        downloads_dir = \(Self.quote(library.downloads.path))
        auto_download_new_chapters = false
        auto_download_limit = 0
        update_interval_hours = 0
        local_scan_secs = 0
        local_scan_on_startup = false
        backup_enabled = true
        backup_interval_hours = 24
        backup_retention_count = 30
        backup_dir = \(Self.quote(library.backups.path))

        """
    }
    func seed(_ library: LocalLibrary, username: String, password: String) throws {
        let config = library.config.appendingPathComponent("config.toml")
        let original = try String(contentsOf: config, encoding: .utf8)
        try Self.validateCredentialEditing(original)
        let clean = Self.withoutCredentialOverrides(original)
        let contents = clean + "\n[auth]\nusername = \(Self.quote(username))\npassword = \(Self.quote(password))\n"
        try privateWrite(Data(contents.utf8), to: config)
    }
    // Preserve all unrelated TOML verbatim. Remove the complete auth table rather
    // than printing its secret values. Unsupported multiline TOML is refused.
    static func validateCredentialEditing(_ text: String) throws {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"\"\"") || value.hasPrefix("'''") {
                throw LibraryFailure(text: "Multiline TOML requires manual review before changing credentials. The original configuration was preserved in recovery.")
            }
        }
    }
    static func withoutCredentialOverrides(_ config: String) -> String {
        var table = ""
        return config.components(separatedBy: .newlines).filter { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                table = String(text.split(separator: "#", maxSplits: 1).first ?? "")
                    .filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            }
            if table == "[auth]" || table.hasPrefix("[auth.") { return false }
            if table.isEmpty {
                let key = String(text.split(separator: "=", maxSplits: 1).first ?? "")
                    .filter { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
                if ["basic_password", "auth", "auth.password", "auth.username"].contains(key) { return false }
            }
            return true
        }.joined(separator: "\n") + "\n"
    }
    func removeSeed(_ library: LocalLibrary) throws {
        let config = library.config.appendingPathComponent("config.toml")
        let text = try String(contentsOf: config, encoding: .utf8)
        try Self.validateCredentialEditing(text)
        try privateWrite(Data(Self.withoutCredentialOverrides(text).utf8), to: config)
    }
    func configString(_ key: String, in text: String) throws -> String {
        // Deliberately accept only unambiguous, quoted top-level path/address
        // values. Unsupported TOML is rejected without changing existing data.
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0] == key else { continue }
            if let data = pair[1].data(using: .utf8), let value = try? JSONDecoder().decode(String.self, from: data) { return value }
            if pair[1].hasPrefix("'"), pair[1].hasSuffix("'") { return String(pair[1].dropFirst().dropLast()) }
        }
        throw LibraryFailure(text: "This configuration's \(key) value is missing or unsupported. No files were changed.")
    }
    func existingLibrary(root: URL) throws -> LocalLibrary {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent("Server/config.toml")
        let config = files.fileExists(atPath: candidate.path) ? root.appendingPathComponent("Server") : root
        let text = try String(contentsOf: config.appendingPathComponent("config.toml"), encoding: .utf8)
        let library = LocalLibrary(root: root, config: config,
            downloads: URL(fileURLWithPath: try configString("downloads_dir", in: text)),
            backups: URL(fileURLWithPath: try configString("backup_dir", in: text)))
        try validateExisting(library)
        return library
    }
    func validateExisting(_ library: LocalLibrary) throws {
        let text = try String(contentsOf: library.config.appendingPathComponent("config.toml"), encoding: .utf8)
        guard try configString("addr", in: text) == "127.0.0.1:\(api.base.port!)",
              files.fileExists(atPath: library.config.appendingPathComponent("sumidoku.db").path) else {
            throw LibraryFailure(text: "Choose an existing library with a localhost configuration and database. It will not be overwritten.")
        }
    }
    func validateAgent(_ library: LocalLibrary) throws {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? [String: Any]
        let args = plist?["ProgramArguments"] as? [String]
        let regular = args == ["/bin/bash", runner.path, library.config.path, binary.path] || args == ["/bin/bash", runner.path, library.config.path]
        let legacy = args == ["/bin/bash", runner.path] && library.config.path == support.path
            && plist?["WorkingDirectory"] as? String == support.path
        guard regular || legacy else { throw LibraryFailure(text: "A different Sumidoku LaunchAgent exists. It was not replaced.") }
    }
    func writeAgent(_ library: LocalLibrary) throws {
        guard !files.fileExists(atPath: agent.path), !service.loaded() else {
            throw LibraryFailure(text: "A Sumidoku service already exists. Connect to it instead of creating another.")
        }
        try privateDirectory(agent.deletingLastPathComponent())
        let logs = home.appendingPathComponent("Library/Logs/Sumidoku")
        try privateDirectory(logs)
        let plist: [String: Any] = ["Label": "app.sumidoku.server",
            "ProgramArguments": ["/bin/bash", runner.path, library.config.path, binary.path],
            "WorkingDirectory": library.config.path, "RunAtLoad": true, "KeepAlive": true,
            "ThrottleInterval": 10, "ExitTimeOut": 30, "ProcessType": "Background", "Umask": 0o077,
            "StandardOutPath": logs.appendingPathComponent("server.log").path,
            "StandardErrorPath": logs.appendingPathComponent("server-error.log").path]
        try privateWrite(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: agent)
    }
    func portIsFree() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(api.base.port!).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
    func waitReady() throws {
        for _ in 0..<80 {
            if let reply = try? api.request("health"), reply.json["status"] as? String == "ok" { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw LibraryFailure(text: "The server did not start. Check the logs; your previous library has not been changed.")
    }
    func persist(_ library: LocalLibrary) throws {
        try privateDirectory(support)
        try privateWrite(JSONEncoder().encode(library), to: descriptor)
    }
    func create(root: URL, username: String, password: String, confirmation: String) throws -> (LocalLibrary, APIReply) {
        try Self.validateOwner(username, password, confirmation)
        guard try current() == nil, !files.fileExists(atPath: support.appendingPathComponent("config.toml").path), !files.fileExists(atPath: agent.path), !service.loaded(), portIsFree() else {
            throw LibraryFailure(text: "An existing library or server was detected. Choose Sign In to connect; no new database was created.")
        }
        guard files.isExecutableFile(atPath: binary.path), files.isExecutableFile(atPath: runner.path) else {
            throw LibraryFailure(text: "The packaged server or runner is missing. Reinstall the client; no library was created.")
        }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let existed = files.fileExists(atPath: root.path, isDirectory: &isDirectory)
        let emptyDirectory = existed && isDirectory.boolValue ? try files.contentsOfDirectory(atPath: root.path).isEmpty : false
        guard !existed || emptyDirectory else {
            throw LibraryFailure(text: "This folder already contains files. Choose Sign In for an existing library, or select a new empty folder. Nothing was overwritten.")
        }
        if !existed { try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let library = LocalLibrary(root: root, config: root.appendingPathComponent("Server"),
                                   downloads: root.appendingPathComponent("Downloads"), backups: root.appendingPathComponent("Backups"))
        var made: [URL] = []
        var agentMade = false
        do {
            for url in [library.config, library.downloads, library.backups] {
                // Exclusive mkdir: never claim, truncate, or roll back an existing directory.
                guard mkdir(url.path, 0o700) == 0 else { throw LibraryFailure(text: "The folder changed during setup. Select an empty folder and try again.") }
                made.append(url)
            }
            let config = library.config.appendingPathComponent("config.toml")
            try privateWrite(Data(baseConfig(library).utf8), to: config)
            try seed(library, username: username, password: password)
            try writeAgent(library); agentMade = true
            try service.start(plist: agent)
            try waitReady()
            let login = try api.login(username: username, password: password)
            let cookie = LocalAPI.cookieHeader(login.cookies)
            _ = try api.request("api/v1/settings", method: "PUT", body: [
                "auto_download_new_chapters": false, "auto_download_limit": 0,
                "downloads.download_ahead": false, "library.update_interval_hours": 0], cookie: cookie)
            let settings = try api.request("api/v1/settings", cookie: cookie)
            guard let download = settings.json["download"] as? [String: Any],
                  download["downloadAhead"] as? Bool == false, download["autoDownloadNewChapters"] as? Bool == false else {
                throw LibraryFailure(text: "The server could not verify metadata-only defaults.")
            }
            try removeSeed(library)
            try persist(library)
            scheduleCommunitySourceBootstrap(library, cookies: login.cookies)
            return (library, login)
        } catch {
            if agentMade {
                do { try service.stop() }
                catch { throw LibraryFailure(text: "Setup stopped before completion. The service could not be stopped; partial files were retained for safe recovery. Check logs before retrying.") }
                try? files.removeItem(at: agent)
            }
            for url in made.reversed() { try? files.removeItem(at: url) }
            if !existed { try? files.removeItem(at: root) }
            throw error
        }
    }
    func connect(root: URL, username: String, password: String) throws -> (LocalLibrary, APIReply) {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let library: LocalLibrary
        if let existing = try current() {
            guard existing.root.standardizedFileURL.resolvingSymlinksInPath().path == root.path else {
                throw LibraryFailure(text: "Another library is already configured. Open its folder in Settings. No service was replaced.")
            }
            library = existing
        } else { library = try existingLibrary(root: root) }
        var madeAgent = false
        if files.fileExists(atPath: agent.path) {
            try validateAgent(library)
        } else {
            guard portIsFree(), !service.loaded() else { throw LibraryFailure(text: "A server already uses this port. Its configuration was not changed.") }
            try writeAgent(library); madeAgent = true
        }
        do {
            if !service.loaded() { try service.start(plist: agent) }
            try waitReady()
            let login = try api.login(username: username, password: password)
            try persist(library)
            scheduleCommunitySourceBootstrap(library, cookies: login.cookies)
            return (library, login)
        } catch {
            if madeAgent { try service.stop(); try files.removeItem(at: agent) }
            throw error
        }
    }
    func coldRecovery(_ library: LocalLibrary) throws -> URL {
        try validateExisting(library)
        try validateAgent(library)
        try service.stop()
        let recovery = library.backups.appendingPathComponent("Recovery-\(UUID().uuidString)")
        try privateDirectory(recovery)
        try files.copyItem(at: library.config, to: recovery.appendingPathComponent("Server"))
        if files.fileExists(atPath: agent.path) { try files.copyItem(at: agent, to: recovery.appendingPathComponent("LaunchAgent.plist")) }
        return recovery
    }
    func changePassword(library: LocalLibrary, current: String, new: String, confirmation: String, cookie: String) throws -> APIReply {
        try Self.validateOwner("owner", new, confirmation)
        // First verify the old password; then snapshot while stopped and remove
        // startup overrides before allowing the server to change the DB hash.
        let status = try api.request("api/v1/auth/status", cookie: cookie)
        guard let username = status.json["username"] as? String else { throw LibraryFailure(text: "Sign in again before changing the password.") }
        _ = try api.login(username: username, password: current)
        _ = try coldRecovery(library)
        try removeSeed(library)
        try service.start(plist: agent); try waitReady()
        let login = try api.login(username: username, password: current)
        _ = try api.request("api/v1/auth/password", method: "PUT", body: ["currentPassword": current, "newPassword": new], cookie: LocalAPI.cookieHeader(login.cookies))
        return try api.login(username: username, password: new)
    }
    func recoverPassword(library: LocalLibrary, username: String, new: String, confirmation: String) throws -> APIReply {
        try Self.validateOwner(username, new, confirmation)
        _ = try coldRecovery(library)
        // Explicit local owner recovery; never delete the database or reset its library.
        try seed(library, username: username, password: new)
        try service.start(plist: agent); try waitReady()
        let login = try api.login(username: username, password: new)
        try removeSeed(library)
        return login
    }
}
