#if COMMUNITY_E2E
import Foundation

/// A compiled disposable transport exercises authentic signed release bytes without
/// publishing test assets or granting the test certificate system-wide trust.
enum CommunityEndToEndDownload {
    static func fetch(_ url: URL,limit: Int) throws -> Data {
        guard let root = ReleaseIdentity.fixtureRoot,
              url.scheme == "https", [nil,443].contains(url.port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.host == "github.com", url.path.hasPrefix("/TTokomon/SumidokuApp/releases/download/"),
              !url.lastPathComponent.isEmpty else { throw UpdateFailure("Foreign fixture download.") }
        let file = URL(fileURLWithPath:root).appendingPathComponent("Distribution").appendingPathComponent(url.lastPathComponent)
        guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
              (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw UpdateFailure("Unsafe fixture download.") }
        return try Data(contentsOf:file)
    }
}
#endif
