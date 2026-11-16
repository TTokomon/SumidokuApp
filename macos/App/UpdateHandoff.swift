import Foundation

struct UpdateHandoff: Codable {
    let paths: InstallationPaths
    let catalog: Data
    let signature: Data
    let version: String
    let payload: URL
    let restore: Bool
    let parent: Int32
    let recovery: URL?
}
struct UpdateSession: Codable { let cookie: String; let username: String }
