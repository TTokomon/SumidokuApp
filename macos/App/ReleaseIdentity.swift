import Foundation

/// Replaced by an immutable generated identity when building a distribution.
/// No private signing material is compiled into the app.
enum ReleaseIdentity {
    static let publicKey: Data? = nil
    static let bundleIdentifier = "app.sumidoku.desktop"
}
