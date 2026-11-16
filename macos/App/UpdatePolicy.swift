import Foundation

struct AppVersion: Comparable, Equatable {
    let components: [Int]
    let prerelease: String?
    init?(_ raw: String) {
        var value = raw
        if value.hasPrefix("desktop-") { value = String(value.dropFirst(8)) }
        if value.hasPrefix("v") { value = String(value.dropFirst()) }
        let build = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pieces = build.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count), numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        components = numbers.map { Int($0)! } + Array(repeating: 0, count: 3 - numbers.count)
        prerelease = pieces.count == 2 ? String(pieces[1]) : nil
        if prerelease?.isEmpty == true { return nil }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components { return lhs.components.lexicographicallyPrecedes(rhs.components) }
        guard let left = lhs.prerelease else { return false }
        guard let right = rhs.prerelease else { return true }
        let a = left.split(separator: "."), b = right.split(separator: ".")
        for (x,y) in zip(a,b) where x != y {
            if let xn = Int(x), let yn = Int(y) { return xn < yn }
            if Int(x) != nil { return true }; if Int(y) != nil { return false }
            return x < y
        }
        return a.count < b.count
    }
}

enum UpdateChannel: String, CaseIterable { case stable, prerelease }
enum AppUpdateState: String { case notChecked, checking, current, available, offline, error, unavailable }
struct DesktopRelease: Decodable, Identifiable {
    let id: Int
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browser_download_url: String }
    var version: AppVersion? { AppVersion(tag_name) }
    // An upstream server-only release is never an application update.
    var desktopArchive: Asset? { assets.first { $0.name.hasPrefix("Sumidoku-Desktop-") && $0.name.hasSuffix("-macOS-arm64.zip") } }
}
struct ReleaseSelection {
    let state: AppUpdateState
    let latest: DesktopRelease?
    let history: [DesktopRelease]
    static func evaluate(_ releases: [DesktopRelease], installed: String, channel: UpdateChannel, developmentBuild: Bool = false) throws -> Self {
        guard let running = AppVersion(installed) else { throw UpdateFailure("The installed application version is invalid.") }
        let eligible = releases.filter { !$0.draft && (channel == .prerelease || (!$0.prerelease && $0.version?.prerelease == nil)) && $0.version != nil && $0.desktopArchive != nil }
            .sorted { $0.version! > $1.version! }
        guard let latest = eligible.first else { return Self(state: .unavailable, latest: nil, history: []) }
        // An unreleased development build cannot claim a confirmed green status.
        let state: AppUpdateState = latest.version! > running ? .available : latest.version! == running && !developmentBuild ? .current : .unavailable
        return Self(state: state, latest: latest, history: eligible)
    }
}
struct UpdateFailure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

struct DistributionPolicy {
    let feed: URL?
    let catalog: URL?
    let publicKey: Data?
    let team: String?
    let coordinatedInstallation: Bool
    init(info: [String: Any]) {
        let url = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        feed = url?.host != nil && url?.query == nil && url?.scheme == "https" && [nil,443].contains(url?.port) && url?.user == nil && url?.password == nil && url?.fragment == nil ? url : nil
        let catalogURL = (info["SumidokuReleaseCatalogURL"] as? String).flatMap(URL.init(string:))
        catalog = catalogURL?.scheme == "https" && [nil,443].contains(catalogURL?.port) && catalogURL?.host == feed?.host && catalogURL?.user == nil && catalogURL?.password == nil && catalogURL?.query == nil && catalogURL?.fragment == nil ? catalogURL : nil
        publicKey = (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count == 32 ? $0 : nil }
        team = (info["SumidokuReleaseTeam"] as? String).flatMap { $0.count == 10 ? $0 : nil }
        coordinatedInstallation = info["SumidokuCoordinatedUpdatesValidated"] as? Bool == true
    }
    var provisioned: Bool { feed != nil && catalog != nil && publicKey != nil && team != nil && coordinatedInstallation }
    func acceptsReplacement(_ info: [String:Any]) -> Bool {
        let next = Self(info:info)
        return provisioned && next.provisioned && next.feed == feed && next.catalog == catalog && next.publicKey == publicKey && next.team == team
            && info["SumidokuDevelopmentBuild"] as? Bool == false
            && info["SumidokuCoordinatedUpdateProtocolVersion"] as? Int == 1
            && info["SUAutomaticallyUpdate"] as? Bool == false && info["SUAllowsAutomaticUpdates"] as? Bool == false
    }
    var blocker: String { "Installation is not enabled until the application, signed catalog, release key, Developer ID/notarization and paired recovery are verified. Checking published releases remains available." }
}
