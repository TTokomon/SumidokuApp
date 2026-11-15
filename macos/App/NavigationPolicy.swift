import Foundation

enum NavigationPolicy {
    static func isLocal(_ url: URL, port: Int = 3000) -> Bool {
        url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
            && (url.port ?? 80) == port && url.user == nil && url.password == nil
    }
}
