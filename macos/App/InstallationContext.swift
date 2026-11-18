import Foundation

/// Production installation scope is fixed. Disposable GUI tests compile a separate scope;
/// no environment variable, Info.plist flag or command-line argument can redirect it.
enum InstallationContext {
    static var home: URL {
        #if COMMUNITY_E2E
        return URL(fileURLWithPath:ReleaseIdentity.fixtureRoot!).appendingPathComponent("Home")
        #else
        return FileManager.default.homeDirectoryForCurrentUser
        #endif
    }
    static var label: String {
        #if COMMUNITY_E2E
        return ReleaseIdentity.fixtureLabel!
        #else
        return "app.sumidoku.server"
        #endif
    }
    static var port: Int {
        #if COMMUNITY_E2E
        return ReleaseIdentity.fixturePort!
        #else
        return 3000
        #endif
    }
    static var serviceArguments: [String] {
        #if COMMUNITY_E2E
        return [home.path,label,String(port)]
        #else
        return []
        #endif
    }
}
