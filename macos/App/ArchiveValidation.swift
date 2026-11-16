import Foundation
import CryptoKit

/// Reject unsafe central-directory paths and symlink ancestors before ditto sees bytes.
/// Only full, bounded ZIP archives are accepted; no packages, deltas or ZIP64.
enum ReleaseArchive {
    static func extract(_ archive: URL, entry: DesktopCatalog.Entry, key: Data, to output: URL) throws -> URL {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count == entry.length, updateDigest(data) == entry.sha256,
              let signature = Data(base64Encoded: entry.signature),
              try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: data) else { throw UpdateFailure("The update archive failed authentication before extraction.") }
        try inspect(data, archive: archive)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw UpdateFailure("Extraction destination already exists.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try UpdateProcess.run("/usr/bin/ditto", ["-x", "-k", "--norsrc", "--noextattr", archive.path, output.path])
        let app = output.appendingPathComponent("Sumidoku.app")
        for file in FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isSymbolicLinkKey])?.allObjects as? [URL] ?? [] {
            guard file.resolvingSymlinksInPath().path.hasPrefix(output.path + "/") else { throw UpdateFailure("An extracted path escaped the application archive.") }
        }
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else { throw UpdateFailure("The archive does not contain Sumidoku.app.") }
        return app
    }
    static func inspect(_ data: Data, archive: URL) throws {
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= data.count else { throw UpdateFailure("Truncated ZIP archive.") }
            return (0..<count).reduce(0) { $0 | Int(data[offset+$1]) << (8*$1) }
        }
        guard data.count >= 22 else { throw UpdateFailure("Invalid ZIP archive.") }
        var end: Int?
        for at in stride(from: data.count-22, through: max(0,data.count-65_557), by: -1) {
            if try number(at,4) == 0x06054b50, at+22+(try number(at+20,2)) == data.count { end = at; break }
        }
        guard let end, try number(end+4,2) == 0, try number(end+6,2) == 0 else { throw UpdateFailure("ZIP64 and split archives are unsupported.") }
        let count = try number(end+10,2), directorySize = try number(end+12,4)
        var at = try number(end+16,4), expanded = 0
        guard count > 0, count < 50_000, at + directorySize == end else { throw UpdateFailure("Invalid ZIP directory.") }
        var paths = Set<String>(), links = [String]()
        for _ in 0..<count {
            guard try number(at,4) == 0x02014b50, try number(at+8,2) & 1 == 0,
                  [0,8].contains(try number(at+10,2)) else { throw UpdateFailure("Unsupported ZIP entry.") }
            let size = try number(at+24,4), nameLength = try number(at+28,2)
            let local = try number(at+42,4)
            let extra = try number(at+30,2), comment = try number(at+32,2), mode = try number(at+38,4) >> 16
            guard at+46+nameLength+extra+comment <= end,
                  let name = String(data: data.subdata(in: at+46..<at+46+nameLength), encoding: .utf8) else { throw UpdateFailure("Invalid ZIP entry name.") }
            let localLength = try number(local+26,2)
            guard try number(local,4) == 0x04034b50, localLength == nameLength,
                  try number(local+8,2) == number(at+10,2),
                  local+30+localLength <= data.count,
                  data.subdata(in: local+30..<local+30+localLength) == data.subdata(in: at+46..<at+46+nameLength) else { throw UpdateFailure("ZIP local/central path mismatch.") }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            let clean = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard name.hasPrefix("Sumidoku.app/"), !name.contains("\\"), !name.contains("\0"),
                  !name.contains(where: { "*?[]\n\r".contains($0) }), !components.contains(".."), !components.contains("."),
                  !components.dropLast().contains(""), paths.insert(clean.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  [0,0o040000,0o100000,0o120000].contains(mode & 0o170000), mode & 0o6000 == 0 else { throw UpdateFailure("Unsafe or duplicate ZIP path.") }
            expanded += size
            guard size < 536_870_912, expanded < 2_147_483_648 else { throw UpdateFailure("ZIP expansion limit exceeded.") }
            if mode & 0o170000 == 0o120000 {
                guard size < 4096 else { throw UpdateFailure("Invalid archive symlink.") }
                let target = try UpdateProcess.output("/usr/bin/unzip", ["-p", archive.path, name]).trimmingCharacters(in: .newlines)
                let base = URL(fileURLWithPath: "/archive/" + clean).deletingLastPathComponent()
                let resolved = URL(fileURLWithPath: target, relativeTo: base).standardizedFileURL.path
                guard !target.hasPrefix("/"), resolved.hasPrefix("/archive/Sumidoku.app/") else { throw UpdateFailure("Archive symlink escaped Sumidoku.app.") }
                links.append(clean)
            }
            at += 46+nameLength+extra+comment
        }
        guard at == end else { throw UpdateFailure("Inconsistent ZIP directory.") }
        for link in links where paths.contains(where: { $0.hasPrefix(link.lowercased()+"/") }) { throw UpdateFailure("An archive entry traverses a symlink.") }
    }
}

enum UpdateProcess {
    static func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "HOME":FileManager.default.homeDirectoryForCurrentUser.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("A required update verification or service command failed.") }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func run(_ executable: String, _ arguments: [String]) throws { _ = try output(executable, arguments) }
}
