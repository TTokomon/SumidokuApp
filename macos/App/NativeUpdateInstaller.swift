import AppKit

/// Sparkle-compatible signed catalog/archive transport with a dedicated paired helper.
/// Sparkle's GUI-only installer is never run alongside this coordinator.
@MainActor
final class NativeUpdateInstaller {
    let bundle: Bundle
    let policy: DistributionPolicy
    let paths: InstallationPaths
    let support: URL
    let beforeHandoff: (Bool) async throws -> UpdateSession
    let handoffFailed: () async -> Void
    private(set) var ready = false
    private(set) var stableVersion: String?
    private(set) var pendingRecovery: URL?
    init(bundle: Bundle = .main, paths: InstallationPaths, support: URL,
         beforeHandoff: @escaping (Bool) async throws -> UpdateSession, handoffFailed: @escaping () async -> Void = {}) {
        self.bundle = bundle; self.policy = DistributionPolicy(info:bundle.infoDictionary ?? [:]); self.paths = paths
        self.support = support; self.beforeHandoff = beforeHandoff; self.handoffFailed = handoffFailed
    }
    func refresh() async {
        ready = false; stableVersion = nil; pendingRecovery = nil
        guard FileManager.default.isExecutableFile(atPath:paths.application.appendingPathComponent("Contents/MacOS/SumidokuUpdateHelper").path), policy.provisioned, !((bundle.infoDictionary?["SumidokuDevelopmentBuild"] as? Bool) ?? true),
              bundle.bundleURL.standardizedFileURL == paths.application.standardizedFileURL,
              (policy.mode == .community || policy.team != nil) else { return }
        let paths = self.paths, support = self.support, policy = self.policy
        do {
            let result = try await Task.detached { () -> (String?,URL?) in
                try verifyReleaseBundle(paths.application,policy.team ?? "")
                try PairedInstallation(paths:paths,team:policy.team ?? "",serviceLabel:InstallationContext.label,service:{ _ in },health:{}).validatePaths()
                let folders = (try? FileManager.default.contentsOfDirectory(at:paths.backups,includingPropertiesForKeys:nil)) ?? []
                let pending = folders.filter { $0.lastPathComponent.hasPrefix("ApplicationUpdate-") }.compactMap { folder -> URL? in
                    let url = folder.appendingPathComponent("update-journal.json")
                    guard let data = try? Data(contentsOf:url), data.count < 65536,
                          let record = try? JSONDecoder().decode(PairedJournal.self,from:data),
                          !["verified","failed-restored-without-database-rollback"].contains(record.phase), record.paths.config.path == paths.config.path else { return nil }
                    return url
                }.first
                let stable = support.appendingPathComponent("Updates/Stable")
                do {
                    let catalog = try DesktopCatalog.authenticated(Data(contentsOf:stable.appendingPathComponent("catalog.json")),signature:Data(contentsOf:stable.appendingPathComponent("catalog.sig")),key:policy.publicKey!)
                    let info = try PairedInstallation.info(stable.appendingPathComponent("Sumidoku.app"))
                    if let entry = catalog.releases.first(where: { $0.channel == "stable" && $0.version == info["SumidokuReleaseVersion"] as? String }) {
                        try PairedInstallation(paths:paths,team:policy.team ?? "",serviceLabel:InstallationContext.label,service:{ _ in },health:{}).validate(stable.appendingPathComponent("Sumidoku.app"),entry:entry)
                        return (entry.version,pending)
                    }
                } catch { /* Invalid recovery never grants downgrade permission. */ }
                return (nil,pending)
            }.value
            ready = true; stableVersion = result.0; pendingRecovery = result.1
        } catch { /* Failed actual bundle/ownership verification leaves installation unavailable. */ }
    }
    func begin(restore: Bool, expectedTag: String?, recover: Bool = false) async throws {
        await refresh()
        guard ready, !restore || stableVersion != nil, recover || pendingRecovery == nil else { throw UpdateFailure(policy.blocker) }
        let files = FileManager.default
        let work = support.appendingPathComponent("Updates/Request-"+UUID().uuidString)
        try files.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if recover {
            guard let journal = pendingRecovery else { throw UpdateFailure("No pending recovery journal is available.") }
            let request = UpdateHandoff(paths:paths,catalog:Data(),signature:Data(),version:"",payload:paths.application,restore:false,parent:getpid(),recovery:journal)
            try await handoff(request,work:work)
            return
        }
        let catalog: AuthenticatedCatalog
        let payload: URL
        let entry: DesktopCatalog.Entry
        if restore {
            let stable = support.appendingPathComponent("Updates/Stable")
            let bytes = try Data(contentsOf:stable.appendingPathComponent("catalog.json"))
            let signature = try Data(contentsOf:stable.appendingPathComponent("catalog.sig"))
            let value = try DesktopCatalog.authenticated(bytes,signature:signature,key:policy.publicKey!)
            guard let found = value.releases.first(where: { $0.version == stableVersion && $0.channel == "stable" }) else { throw UpdateFailure("The verified Stable recovery is unavailable.") }
            entry = found; catalog = AuthenticatedCatalog(bytes:bytes,signature:signature,value:value)
            payload = stable.appendingPathComponent("Sumidoku.app")
        } else {
            catalog = try await AuthenticatedCatalog.fetch(policy:policy)
            guard let found = catalog.value.releases.first(where: { $0.tag == expectedTag }) else { throw UpdateFailure("The selected release is not in the trusted catalog. Check for updates again.") }
            entry = found
            let archive = work.appendingPathComponent("update.zip")
            let bytes = try await BoundedReleaseDownload.fetch(entry.url,limit:entry.length,archive:true)
            try bytes.write(to:archive,options:.atomic)
            let key = policy.publicKey!
            payload = try await Task.detached { try ReleaseArchive.extract(archive,entry:entry,key:key,to:work.appendingPathComponent("Extracted")) }.value
        }
        guard policy.acceptsReplacement(try PairedInstallation.info(payload)) else { throw UpdateFailure("The release is not qualified for coordinated updates, or changes pinned release trust. The installed app is unchanged.") }
        try PairedInstallation(paths:paths,team:policy.team ?? "",serviceLabel:InstallationContext.label,service:{ _ in },health:{}).validate(payload,entry:entry)
        let request = UpdateHandoff(paths:paths,catalog:catalog.bytes,signature:catalog.signature,version:entry.version,payload:payload,restore:restore,parent:getpid(),recovery:nil)
        try await handoff(request,work:work)
    }
    private func handoff(_ request: UpdateHandoff, work: URL) async throws {
        let files = FileManager.default
        let url = work.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to:url,options:.atomic)
        try files.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let session = try await beforeHandoff(request.recovery != nil)
        let helper = Process(); helper.executableURL = paths.application.appendingPathComponent("Contents/MacOS/SumidokuUpdateHelper"); helper.arguments = [url.path]
        let input = Pipe(), output = Pipe()
        helper.standardInput = input; helper.standardOutput = output; helper.standardError = FileHandle.nullDevice
        try helper.run()
        try input.fileHandleForWriting.write(contentsOf:JSONEncoder().encode(session)); try input.fileHandleForWriting.close()
        // The helper validates all trust/ownership checks before acknowledging the handoff.
        let acknowledgement = await Task.detached { output.fileHandleForReading.availableData }.value
        guard String(decoding:acknowledgement,as:UTF8.self).hasPrefix("READY\n") else { throw UpdateFailure("The coordinated helper refused the handoff. The installed app is unchanged.") }
        NSApp.terminate(nil)
    }
}
