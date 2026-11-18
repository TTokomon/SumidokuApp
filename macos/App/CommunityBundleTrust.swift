import Foundation
import CryptoKit

/// Publisher-authenticated contents, independent of paid Apple certificates.
/// Ad-hoc code signatures still enforce macOS bundle/resource consistency.
enum CommunityBundleTrust {
    static let manifestName = "Contents/Resources/community-seal.json"
    static let signatureName = "Contents/Resources/community-seal.sig"
    struct Seal: Codable, Equatable {
        let format: Int
        let bundleIdentifier: String
        let entries: [Entry]
    }
    struct Entry: Codable, Equatable {
        let path: String
        let kind: String
        let mode: Int
        let digest: String?
        let target: String?
    }
    static func executableDigest(_ url: URL) throws -> String {
        var bytes = [UInt8](try Data(contentsOf:url))
        func word(_ at: Int) throws -> Int {
            guard at >= 0, at+4 <= bytes.count else { throw UpdateFailure("Truncated executable.") }
            return (0..<4).reduce(0) { $0 | Int(bytes[at+$1]) << (8*$1) }
        }
        guard try word(0) == 0xfeedfacf, try word(4) == 0x0100000c else { throw UpdateFailure("A thin arm64 main executable is required.") }
        let count = try word(16), size = try word(20)
        guard count < 4096, 32+size <= bytes.count else { throw UpdateFailure("Invalid executable commands.") }
        var at = 32, signature: (Int,Int,Int)?, linkedit: Int?
        for _ in 0..<count {
            let command = try word(at), length = try word(at+4)
            guard length >= 8, at+length <= 32+size else { throw UpdateFailure("Invalid executable command.") }
            if command == 0x1d {
                guard length == 16, signature == nil else { throw UpdateFailure("Ambiguous executable signature.") }
                signature = (at,try word(at+8),try word(at+12))
            }
            if command == 0x19, length >= 72 {
                let name = String(decoding:bytes[at+8..<at+24].prefix(while:{$0 != 0}),as:UTF8.self)
                if name == "__LINKEDIT" { linkedit = at }
            }
            at += length
        }
        guard let (command,offset,length) = signature, let segment = linkedit,
              offset >= 32+size, length > 0, offset+length == bytes.count else { throw UpdateFailure("The executable signature is not a bounded trailing blob.") }
        // Bind the signature offset, all code and load commands. Only values changed
        // by re-signing the enclosing resource envelope are normalized.
        bytes.replaceSubrange(command+12..<command+16,with:Data(repeating:0,count:4))
        bytes.replaceSubrange(segment+32..<segment+40,with:Data(repeating:0,count:8))
        bytes.replaceSubrange(segment+48..<segment+56,with:Data(repeating:0,count:8))
        return updateDigest(Data(bytes.prefix(offset)))
    }
    static func contents(_ app: URL) throws -> Seal {
        let root = app.standardizedFileURL.resolvingSymlinksInPath()
        let values: Set<URLResourceKey> = [.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey]
        guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(values)) else { throw UpdateFailure("Application contents are missing.") }
        var entries = [Entry]()
        while let file = iterator.nextObject() as? URL {
            // Foundation enumeration may return /tmp for a /private/tmp root.
            // Resolve the parent alias, preserving a leaf symlink for inventory.
            let normalized = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent)
            guard normalized.path.hasPrefix(root.path+"/") else { throw UpdateFailure("Bundle enumeration escaped its root.") }
            let path = String(normalized.path.dropFirst(root.path.count+1))
            if path.split(separator:"/").contains("_CodeSignature") {
                let type = try file.resourceValues(forKeys:values)
                guard (file.lastPathComponent == "_CodeSignature" && type.isDirectory == true && type.isSymbolicLink != true)
                    || (file.lastPathComponent == "CodeResources" && file.deletingLastPathComponent().lastPathComponent == "_CodeSignature" && type.isRegularFile == true && type.isSymbolicLink != true) else { throw UpdateFailure("Unexpected code-signature envelope contents.") }
                continue
            }
            if [manifestName,signatureName].contains(path) { continue }
            guard !path.isEmpty, !path.contains("\\"), !path.split(separator:"/").contains(".."), entries.count < 50_000 else { throw UpdateFailure("Unsafe bundle path.") }
            let info = try file.resourceValues(forKeys:values)
            let mode = (try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            if info.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath:file.path)
                guard !target.hasPrefix("/"), file.resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else { throw UpdateFailure("A bundle symlink escaped its root.") }
                entries.append(Entry(path:path,kind:"symlink",mode:mode,digest:nil,target:target));iterator.skipDescendants()
            } else if info.isDirectory == true {
                entries.append(Entry(path:path,kind:"directory",mode:mode,digest:nil,target:nil))
            } else if info.isRegularFile == true {
                let hash = try path == "Contents/MacOS/Sumidoku" ? executableDigest(file) : updateDigest(file)
                entries.append(Entry(path:path,kind:"file",mode:mode,digest:hash,target:nil))
            } else { throw UpdateFailure("Unsupported application filesystem entry.") }
        }
        let info = try PairedInstallation.info(app)
        guard let identifier = info["CFBundleIdentifier"] as? String else { throw UpdateFailure("Missing bundle identity.") }
        return Seal(format:1,bundleIdentifier:identifier,entries:entries.sorted{$0.path < $1.path})
    }
    static func verify(_ app: URL, key: Data, identifier: String) throws {
        let bytes = try Data(contentsOf:app.appendingPathComponent(manifestName))
        guard bytes.count < 16_777_216,
              let signature = Data(base64Encoded:try String(contentsOf:app.appendingPathComponent(signatureName),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)),
              try Curve25519.Signing.PublicKey(rawRepresentation:key).isValidSignature(signature,for:bytes) else { throw UpdateFailure("The community bundle seal is not signed by the pinned publisher key.") }
        let declared = try JSONDecoder().decode(Seal.self,from:bytes)
        guard declared.format == 1, declared.bundleIdentifier == identifier, try contents(app) == declared else { throw UpdateFailure("The community application contents failed publisher verification.") }
        for path in ["Contents/MacOS/Sumidoku","Contents/MacOS/SumidokuUpdateHelper","Contents/Resources/sumidoku-server"] {
            let header = try Data(contentsOf:app.appendingPathComponent(path),options:.mappedIfSafe).prefix(8)
            guard Array(header) == [0xcf,0xfa,0xed,0xfe,0x0c,0,0,1] else { throw UpdateFailure("The community release requires arm64 executables.") }
        }
        try UpdateProcess.run("/usr/bin/codesign",["--verify","--deep","--strict",app.path])
    }
}

func verifyReleaseBundle(_ app: URL, _ team: String) throws {
    let info = try PairedInstallation.info(app)
    let policy = DistributionPolicy(info:info)
    if policy.mode == .community {
        guard let key = ReleaseIdentity.publicKey, key == policy.publicKey,
              policy.provisioned, info["SumidokuDevelopmentBuild"] as? Bool == false else { throw UpdateFailure("Community trust is not explicitly provisioned with the compiled publisher key.") }
        try CommunityBundleTrust.verify(app,key:key,identifier:ReleaseIdentity.bundleIdentifier)
    } else { try verifyDeveloperRelease(app,team) }
}
