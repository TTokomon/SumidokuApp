import Foundation
import CryptoKit

/// This catalog accompanies the Sparkle 2 appcast and uses the same Ed25519 key.
/// Authenticate the exact bytes before decoding any URLs or installation metadata.
struct DesktopCatalog: Codable {
    let format: Int
    let releases: [Entry]
    struct Entry: Codable, Equatable {
        let version: String
        let build: Int
        let channel: String
        let url: URL
        let length: Int
        let signature: String
        let sha256: String
        let clientSha256: String
        let serverSha256: String
        let sourceRevision: String
        let schema: Int
        var tag: String { "desktop-v" + version }
    }
    static func authenticated(_ bytes: Data, signature: Data, key: Data) throws -> Self {
        guard bytes.count <= 2_000_000,
              try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: bytes) else {
            throw UpdateFailure("The release catalog signature is invalid. Nothing was installed.")
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.format == 1, value.releases.count <= 100,
              Set(value.releases.map(\.version)).count == value.releases.count,
              Set(value.releases.map(\.build)).count == value.releases.count else { throw UpdateFailure("Unsupported or ambiguous release catalog.") }
        for entry in value.releases {
            guard entry.version.range(of:"^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-beta\\.[1-9][0-9]*)?$",options:.regularExpression) != nil, let version = AppVersion(entry.version), entry.build > 0,
                  entry.channel == (version.prerelease == nil ? "stable" : "beta"),
                  entry.schema > 0, (1...536_870_912).contains(entry.length),
                  [entry.sha256, entry.clientSha256, entry.serverSha256].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }),
                  entry.sourceRevision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  Data(base64Encoded: entry.signature)?.count == 64,
                  entry.url.scheme == "https", entry.url.host == "github.com", [nil,443].contains(entry.url.port), entry.url.user == nil,
                  entry.url.password == nil, entry.url.query == nil, entry.url.fragment == nil,
                  entry.url.path == "/TTokomon/SumidokuApp/releases/download/\(entry.tag)/Sumidoku-Desktop-\(entry.version)-macOS-arm64.zip" else {
                throw UpdateFailure("The signed release metadata is incompatible or unsafe.")
            }
        }
        return value
    }
    func latest(channel: UpdateChannel) -> Entry? {
        releases.filter { channel == .prerelease || $0.channel == "stable" }.max { AppVersion($0.version)! < AppVersion($1.version)! }
    }
}

func updateDigest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
func updateDigest(_ url: URL) throws -> String { updateDigest(try Data(contentsOf: url, options: .mappedIfSafe)) }

final class BoundedReleaseDownload: NSObject, URLSessionDownloadDelegate {
    let limit: Int64
    let hosts: Set<String>
    init(limit: Int, hosts: Set<String>) { self.limit = Int64(limit); self.hosts = hosts }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == "https" && url?.user == nil && url?.password == nil && [nil,443].contains(url?.port) && url?.fragment == nil && hosts.contains(url?.host ?? "") ? request : nil)
    }
    static func fetch(_ url: URL, limit: Int, archive: Bool = false) async throws -> Data {
        guard url.scheme == "https", let host = url.host, url.user == nil, url.password == nil, url.fragment == nil else { throw UpdateFailure("A trusted HTTPS release endpoint is required.") }
        let hosts: Set<String> = archive ? ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"] : [host]
        let delegate = Self(limit: limit, hosts: hosts)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw UpdateFailure("Release download failed or exceeded its size limit.") }
        return try Data(contentsOf: file)
    }
}

struct AuthenticatedCatalog {
    let bytes: Data
    let signature: Data
    let value: DesktopCatalog
    static func fetch(policy: DistributionPolicy, download: (URL,Int) async throws -> Data = { try await BoundedReleaseDownload.fetch($0,limit:$1) }) async throws -> Self {
        guard let url = policy.catalog, let key = policy.publicKey else { throw UpdateFailure(policy.blocker) }
        let bytes = try await download(url,2_000_000)
        let encoded = try await download(URL(string: url.absoluteString + ".sig")!,256)
        guard let signature = Data(base64Encoded: String(decoding: encoded, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw UpdateFailure("The release catalog signature is missing.") }
        return Self(bytes: bytes, signature: signature, value: try DesktopCatalog.authenticated(bytes, signature: signature, key: key))
    }
}
