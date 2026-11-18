import Foundation
import CryptoKit
import Darwin

@main
struct TrustTool {
    static func main() {
        do { try execute() }
        catch { fputs("Verification failed: \(error.localizedDescription)\n",stderr);exit(1) }
    }
    static func execute() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "seal" {
            let seal = try CommunityBundleTrust.contents(URL(fileURLWithPath:args[2]))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(seal).write(to:URL(fileURLWithPath:args[2]).appendingPathComponent(CommunityBundleTrust.manifestName))
        } else if args.count == 4, args[1] == "bundle", let key = Data(base64Encoded:args[3]), key.count == 32 {
            let app = URL(fileURLWithPath:args[2]), info = try PairedInstallation.info(app)
            let identifier = info["CFBundleIdentifier"] as? String ?? ""
            guard identifier == "app.sumidoku.desktop" || (info["SumidokuEndToEndFixture"] as? Bool == true && identifier.hasPrefix("app.sumidoku.fixture.")) else { throw UpdateFailure("Unexpected bundle identity.") }
            try CommunityBundleTrust.verify(app,key:key,identifier:identifier)
            print("Verified publisher-authenticated application")
        } else if args.count == 5, args[1] == "signed-file", let key = Data(base64Encoded:args[4]),
                  let signature = Data(base64Encoded:try String(contentsOfFile:args[3],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) {
            let bytes = try Data(contentsOf:URL(fileURLWithPath:args[2]))
            guard bytes.count < 2_000_000, try Curve25519.Signing.PublicKey(rawRepresentation:key).isValidSignature(signature,for:bytes) else { throw UpdateFailure("Invalid signed qualification.") }
        } else if args.count == 7, args[1] == "archive", let key = Data(base64Encoded:args[5]),
                  let signature = Data(base64Encoded:try String(contentsOfFile:args[4],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) {
            let catalog = try DesktopCatalog.authenticated(Data(contentsOf:URL(fileURLWithPath:args[3])),signature:signature,key:key)
            guard let entry = catalog.releases.first(where:{$0.version == args[6]}) else { throw UpdateFailure("Release is not in the authenticated catalog.") }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sumidoku-release-verify-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let app = try ReleaseArchive.extract(URL(fileURLWithPath:args[2]),entry:entry,key:key,to:root)
            let info = try PairedInstallation.info(app), policy = DistributionPolicy(info:info)
            guard policy.provisioned, policy.acceptsReplacement(info), policy.publicKey == key, info["SumidokuEndToEndFixture"] as? Bool != true,
                  info["SumidokuDevelopmentBuild"] as? Bool == false, info["CFBundleIdentifier"] as? String == "app.sumidoku.desktop",
                  info["SumidokuReleaseVersion"] as? String == entry.version,
                  info["CFBundleVersion"] as? String == String(entry.build),
                  try updateDigest(app.appendingPathComponent("Contents/MacOS/Sumidoku")) == entry.clientSha256,
                  try updateDigest(app.appendingPathComponent("Contents/Resources/sumidoku-server")) == entry.serverSha256 else { throw UpdateFailure("Unqualified production release bundle.") }
            if policy.mode == .community { try CommunityBundleTrust.verify(app,key:key,identifier:"app.sumidoku.desktop") }
            else { try verifyDeveloperRelease(app,policy.team ?? "") }
        } else {
            guard args.count == 5, args[1] == "catalog", let key = Data(base64Encoded:args[4]),
                  let signature = Data(base64Encoded:try String(contentsOfFile:args[3],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw UpdateFailure("Expected seal, bundle or catalog verification arguments.") }
            let value = try DesktopCatalog.authenticated(Data(contentsOf:URL(fileURLWithPath:args[2])),signature:signature,key:key)
            print("Verified catalog entries: \(value.releases.count)")
        }
    }
}
