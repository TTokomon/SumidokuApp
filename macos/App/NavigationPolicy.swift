import Foundation

enum NavigationPolicy {
    static func isLocal(_ url: URL) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
            && (url.port ?? 80) == 3000 && url.user == nil && url.password == nil
    }
}
