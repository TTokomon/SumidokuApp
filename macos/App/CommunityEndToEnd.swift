#if COMMUNITY_E2E
import AppKit
import Foundation

@MainActor
enum CommunityEndToEnd {
    static var attached = false
    static func attach(controller: ServerController,updates: AppUpdates) {
        guard !attached, let root = ReleaseIdentity.fixtureRoot else { return }; attached = true
        let folder = URL(fileURLWithPath:root)
        Task { @MainActor in
            while true {
                let status: [String:Any] = ["version":updates.installed,"pid":ProcessInfo.processInfo.processIdentifier,
                    "signedIn":controller.signedIn,"canInstall":updates.canInstall,"canRestore":updates.canRestoreStable,
                    "detail":updates.detail,"window":NSApp.windows.contains{$0.isVisible},"loading":controller.webView.isLoading]
                if let bytes = try? JSONSerialization.data(withJSONObject:status) { try? bytes.write(to:folder.appendingPathComponent("status.json"),options:.atomic) }
                let command = folder.appendingPathComponent("command.txt")
                if let action = try? String(contentsOf:command,encoding:.utf8) {
                    try? FileManager.default.removeItem(at:command)
                    if action == "update" {
                        updates.channel = .prerelease;updates.check();await updates.waitForCheck();await updates.refreshInstallation();updates.install()
                    } else if action == "restore" { await updates.refreshInstallation();updates.install(restore:true) }
                    else if action == "quit" { NSApp.terminate(nil) }
                }
                try? await Task.sleep(nanoseconds:250_000_000)
            }
        }
    }
}
#endif
