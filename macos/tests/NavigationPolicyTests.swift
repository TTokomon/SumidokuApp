import Foundation

@main
struct NavigationPolicyTests {
    static func main() {
        let allowed = ["http://127.0.0.1:3000", "http://localhost:3000/library", "http://LOCALHOST:3000/login"]
        let blocked = [
            "https://example.com", "http://127.0.0.1:3001", "http://localhost",
            "https://127.0.0.1:3000", "http://127.0.0.1.example.com:3000",
            "http://localhost.example.com:3000", "file:///etc/hosts",
            "http://unexpected@localhost:3000", "http://name:unexpected@127.0.0.1:3000"
        ]
        for text in allowed { precondition(NavigationPolicy.isLocal(URL(string: text)!), "Local URL rejected: \(text)") }
        for text in blocked { precondition(!NavigationPolicy.isLocal(URL(string: text)!), "Nonlocal URL accepted: \(text)") }
        print("PASS: local-origin navigation policy (\(allowed.count + blocked.count) cases)")
    }
}
