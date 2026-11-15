import Foundation

final class UnusedService: LibraryService {
    func loaded() -> Bool { false }
    func start(plist: URL) throws { fatalError("Fixture must not manage services") }
    func stop() throws { fatalError("Fixture must not manage services") }
    func restart() throws { fatalError("Fixture must not manage services") }
}

@main
struct CommunitySourceTests {
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("sumidoku-community-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let library = LocalLibrary(root: root, config: root, downloads: root.appendingPathComponent("Downloads"), backups: root.appendingPathComponent("Backups"))
        let marker = root.appendingPathComponent(".aidoku-community-list-initialized")
        var assertions = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            assertions += 1; print("PASS: \(message)")
        }
        var requests = 0, subscriptions = 0
        var offline = false
        var entries: [[String: Any]] = []
        let manager = LibraryManager(home: root, binary: root.appendingPathComponent("unused"), runner: root.appendingPathComponent("unused"), service: UnusedService(), sourceListRequest: { method, body, cookie in
            requests += 1
            guard cookie == "fixture-session" else { throw URLError(.userAuthenticationRequired) }
            if offline { throw URLError(.notConnectedToInternet) }
            if method == "POST" {
                subscriptions += 1
                expect(body?["url"] as? String == "https://aidoku-community.github.io/sources/index.min.json", "bootstrap selects only the official published index")
                entries.append(["url": body!["url"]!])
            }
            return try JSONSerialization.data(withJSONObject: entries)
        })
        offline = true
        do { try manager.ensureCommunitySourceList(library, cookie: "fixture-session"); expect(false, "offline request must defer") } catch {}
        expect(!files.fileExists(atPath: marker.path), "offline failure leaves no initialization marker")
        offline = false
        try manager.ensureCommunitySourceList(library, cookie: "fixture-session")
        expect(subscriptions == 1 && entries.count == 1, "recovery creates exactly one community subscription")
        let permissions = try files.attributesOfItem(atPath: marker.path)[.posixPermissions] as! NSNumber
        expect(permissions.intValue == 0o600, "initialization marker is private")
        let previousRequests = requests
        entries = [] // Deliberate subscription removal, not package/library removal.
        try manager.ensureCommunitySourceList(library, cookie: "fixture-session")
        expect(requests == previousRequests && entries.isEmpty, "intentional removal survives reconnect without recreation")
        var reopenedRequests = 0
        let reopened = LibraryManager(home: root, binary: root.appendingPathComponent("unused"), runner: root.appendingPathComponent("unused"), service: UnusedService(), sourceListRequest: { _, _, _ in
            reopenedRequests += 1
            return Data("[]".utf8)
        })
        try reopened.ensureCommunitySourceList(library, cookie: "fixture-session")
        expect(reopenedRequests == 0, "deliberate removal survives manager recreation from persisted storage")
        try files.removeItem(at: marker)
        entries = [["url": "https://aidoku-community.github.io/sources/index.json"]]
        try manager.ensureCommunitySourceList(library, cookie: "fixture-session")
        expect(subscriptions == 1, "existing official index alias does not duplicate the subscription")
        try files.removeItem(at: marker)
        entries = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do { try manager.ensureCommunitySourceList(library, cookie: "fixture-session") }
            catch { fatalError("Concurrent fixture bootstrap failed") }
        }
        expect(subscriptions == 2 && entries.count == 1, "concurrent authenticated bootstrap runs subscribe once")
        print("PASS: \(assertions) community bootstrap assertions; fixture transport only, no public network or real service")
    }
}
