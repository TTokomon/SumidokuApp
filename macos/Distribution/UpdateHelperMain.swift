import Foundation
import AppKit
import Darwin

@main
struct UpdateHelperMain {
    static func main() {
        do { try execute() }
        catch { fputs("Coordinated update stopped; inspect the retained recovery journal.\n",stderr); exit(1) }
    }
    static func execute() throws {
        guard CommandLine.arguments.count == 2 else { throw UpdateFailure("A private update request is required.") }
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/Sumidoku")
        let work = support.appendingPathComponent("Updates")
        let requestURL = URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
        guard requestURL.path.hasPrefix(work.path+"/Request-"), requestURL.resolvingSymlinksInPath() == requestURL,
              (try requestURL.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) < 2_100_000 else { throw UpdateFailure("Unsafe update request.") }
        let request = try JSONDecoder().decode(UpdateHandoff.self,from:Data(contentsOf:requestURL))
        let app = URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        guard request.parent == getppid(), request.paths.application.standardizedFileURL == app,
              request.paths.runtime.standardizedFileURL == support.appendingPathComponent("bin/sumidoku-server-fork"),
              request.paths.runner.standardizedFileURL == support.appendingPathComponent("bin/run-server.sh"),
              request.paths.agent.standardizedFileURL == home.appendingPathComponent("Library/LaunchAgents/app.sumidoku.server.plist"), request.paths.port == 3000 else { throw UpdateFailure("The helper only controls its own application and managed server.") }
        let info = try PairedInstallation.info(app), policy = DistributionPolicy(info:info)
        guard policy.provisioned, let key = policy.publicKey, let team = policy.team else { throw UpdateFailure(policy.blocker) }
        try verifyDeveloperRelease(app,team)
        let lock = open(work.appendingPathComponent("installation.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard lock >= 0, flock(lock,LOCK_EX|LOCK_NB) == 0 else { throw UpdateFailure("An update/recovery is already active.") }
        defer { close(lock) }
        guard try updateDigest(request.paths.runner) == updateDigest(app.appendingPathComponent("Contents/Resources/run-server.sh")) else { throw UpdateFailure("The managed runner differs from the signed application contract.") }
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        guard bytes.count < 16_384 else { throw UpdateFailure("Invalid session handoff.") }
        let session = try JSONDecoder().decode(UpdateSession.self,from:bytes)
        guard (request.recovery != nil || !session.username.isEmpty), !session.cookie.contains("\r"), !session.cookie.contains("\n") else { throw UpdateFailure("Sign in before updating.") }
        let api = LocalAPI(port:request.paths.port)
        let descriptor = try JSONDecoder().decode(LocalLibrary.self,from:Data(contentsOf:support.appendingPathComponent("desktop-library.json")))
        guard descriptor.config == request.paths.config, descriptor.backups == request.paths.backups else { throw UpdateFailure("The request does not match the saved library descriptor.") }
        let serviceHelper = requestURL.deletingLastPathComponent().appendingPathComponent("service.sh")
        try files.copyItem(at:app.appendingPathComponent("Contents/Resources/service.sh"),to:serviceHelper)
        func verifyOwnedListener() throws {
            let job = try UpdateProcess.output("/bin/launchctl",["print","gui/\(getuid())/app.sumidoku.server"])
            let runner = job.components(separatedBy:.newlines).compactMap { line -> Int? in
                let words = line.split(whereSeparator: { $0.isWhitespace }); return words.count == 3 && words[0] == "pid" && words[1] == "=" ? Int(words[2]) : nil
            }.first
            let listing = try UpdateProcess.output("/usr/sbin/lsof",["-nP","-iTCP:\(request.paths.port)","-sTCP:LISTEN","-Fpn"]).components(separatedBy:.newlines)
            let listeners = listing.filter { $0.hasPrefix("p") }.map { String($0.dropFirst()) }
            let addresses = listing.filter { $0.hasPrefix("n") }
            guard let runner, listeners.count == 1, !addresses.isEmpty,
                  addresses.allSatisfy({ $0 == "n127.0.0.1:\(request.paths.port)" }),
                  Int(try UpdateProcess.output("/bin/ps",["-p",listeners[0],"-o","ppid="]).trimmingCharacters(in:.whitespacesAndNewlines)) == runner else { throw UpdateFailure("The listener is not the owned localhost server.") }
        }
        let transaction = PairedInstallation(paths:request.paths,team:team,service:{ action in
            try UpdateProcess.run("/bin/bash",[serviceHelper.path,action])
            if action == "stop" {
                let listener = try? UpdateProcess.output("/usr/sbin/lsof",["-nP","-tiTCP:\(request.paths.port)","-sTCP:LISTEN"])
                guard listener?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false else { throw UpdateFailure("A server is still bound to the managed port.") }
            }
        },health:{
            try verifyOwnedListener()
            guard try api.request("health").response.statusCode == 200 else { throw UpdateFailure("Server health verification failed.") }
            let status = try api.request("api/v1/auth/status",cookie:session.cookie)
            if request.recovery != nil && session.username.isEmpty {
                guard status.response.statusCode == 200 else { throw UpdateFailure("Recovered authentication endpoint is unavailable.") }
                // Offline recovery may need a fresh sign-in; it never disables authentication.
            } else {
                guard status.json["username"] as? String == session.username else { throw UpdateFailure("Preserved login verification failed.") }
            }
        },relaunch:{ recovery in
            let journal = recovery.appendingPathComponent("update-journal.json")
            try UpdateProcess.run("/usr/bin/open",["-n",request.paths.application.path,"--args","--complete-update",journal.path])
            let ack = recovery.appendingPathComponent("relaunch-verified.json")
            for _ in 0..<150 {
                if let bytes = try? Data(contentsOf:ack), let value = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                   value["version"] as? String == request.version, value["signedIn"] as? Bool == true { return }
                Thread.sleep(forTimeInterval:0.2)
            }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier:"app.sumidoku.desktop").filter { $0.bundleURL?.standardizedFileURL.path == request.paths.application.standardizedFileURL.path }
            for client in running { client.terminate() }
            for _ in 0..<100 {
                if running.allSatisfy(\.isTerminated) { break }
                Thread.sleep(forTimeInterval:0.2)
            }
            guard running.allSatisfy(\.isTerminated) else { throw ManualUpdateRecovery() }
            throw UpdateFailure("The relaunched app did not verify its window and preserved login.")
        })
        try transaction.validatePaths()
        if let url = request.recovery {
            guard url.standardizedFileURL.path.hasPrefix(request.paths.backups.path+"/ApplicationUpdate-"),
                  url.lastPathComponent == "update-journal.json", url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw UpdateFailure("Unsafe recovery journal path.") }
            var journal = try JSONDecoder().decode(PairedJournal.self,from:Data(contentsOf:url))
            print("READY");fflush(stdout)
            try waitForParent(request.parent)
            try transaction.recover(&journal)
            try UpdateProcess.run("/usr/bin/open",[request.paths.application.path])
            return
        }
        let catalog = try DesktopCatalog.authenticated(request.catalog,signature:request.signature,key:key)
        guard let entry = catalog.releases.first(where: { $0.version == request.version }), !request.restore || entry.channel == "stable" else { throw UpdateFailure("Untrusted release selection.") }
        guard policy.acceptsReplacement(try PairedInstallation.info(request.payload)) else { throw UpdateFailure("The replacement is unqualified or changes pinned release trust.") }
        try transaction.validatePaths(); try transaction.validate(request.payload,entry:entry)
        // A beta is not offered without a verifiable current Stable recovery baseline.
        let old = info["SumidokuReleaseVersion"] as? String ?? info["CFBundleShortVersionString"] as? String ?? ""
        guard let oldVersion = AppVersion(old) else { throw UpdateFailure("Unknown installed version.") }
        if !request.restore, oldVersion.prerelease != nil {
            let stable = work.appendingPathComponent("Stable")
            let saved = try DesktopCatalog.authenticated(Data(contentsOf:stable.appendingPathComponent("catalog.json")),signature:Data(contentsOf:stable.appendingPathComponent("catalog.sig")),key:key)
            let prior = try PairedInstallation.info(stable.appendingPathComponent("Sumidoku.app"))
            guard let baseline = saved.releases.first(where: { $0.channel == "stable" && $0.version == prior["SumidokuReleaseVersion"] as? String }) else { throw UpdateFailure("Beta updates require a verified retained Stable baseline.") }
            try transaction.validate(stable.appendingPathComponent("Sumidoku.app"),entry:baseline)
        }
        if !request.restore, oldVersion.prerelease == nil {
            guard let stable = catalog.releases.first(where: { $0.version == old && $0.channel == "stable" }) else { throw UpdateFailure("The installed Stable baseline is not authenticated in the catalog.") }
            try transaction.validate(app,entry:stable)
            let destination = work.appendingPathComponent("Stable")
            if files.fileExists(atPath:destination.path) {
                try transaction.validate(destination.appendingPathComponent("Sumidoku.app"),entry:stable)
            } else {
            try files.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try files.copyItem(at:app,to:destination.appendingPathComponent("Sumidoku.app"))
            try request.catalog.write(to:destination.appendingPathComponent("catalog.json"),options:.atomic)
            try request.signature.write(to:destination.appendingPathComponent("catalog.sig"),options:.atomic)
            }
        }
        if request.restore {
            guard request.payload.standardizedFileURL == work.appendingPathComponent("Stable/Sumidoku.app") else { throw UpdateFailure("Restore Stable only accepts the verified retained baseline.") }
        } else {
            guard request.payload.resolvingSymlinksInPath().path.hasPrefix(requestURL.deletingLastPathComponent().path+"/") else { throw UpdateFailure("Unsafe update payload path.") }
        }
        try verifyOwnedListener()
        print("READY"); fflush(stdout)
        try waitForParent(request.parent)
        _ = try transaction.apply(request.payload,entry:entry,restore:request.restore)
    }
    static func waitForParent(_ parent: Int32) throws {
        for _ in 0..<600 {
            if kill(parent,0) != 0 && errno == ESRCH { break }
            Thread.sleep(forTimeInterval:0.2)
        }
        guard kill(parent,0) != 0 && errno == ESRCH else { throw UpdateFailure("The application did not quit; nothing was replaced.") }
    }
}
