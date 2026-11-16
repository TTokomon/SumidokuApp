import Foundation

@main
struct TrustTool {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5, args[1] == "catalog", let key = Data(base64Encoded:args[4]),
              let signature = Data(base64Encoded:try String(contentsOfFile:args[3],encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw UpdateFailure("Usage: trust-tool catalog file.json file.sig public-key") }
        let value = try DesktopCatalog.authenticated(Data(contentsOf:URL(fileURLWithPath:args[2])),signature:signature,key:key)
        print("Verified catalog entries: \(value.releases.count)")
    }
}
