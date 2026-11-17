import Foundation
import Darwin

struct InstallationPaths: Codable, Equatable {
    let application: URL
    let config: URL
    let backups: URL
    let runtime: URL
    let agent: URL
    let runner: URL
    let port: Int
    static func == (left: Self, right: Self) -> Bool {
        left.port == right.port && zip([left.application,left.config,left.backups,left.runtime,left.agent,left.runner],
            [right.application,right.config,right.backups,right.runtime,right.agent,right.runner]).allSatisfy {
                $0.standardizedFileURL.resolvingSymlinksInPath().path == $1.standardizedFileURL.resolvingSymlinksInPath().path
            }
    }
}

struct PairedJournal: Codable {
    var phase: String
    let id: String
    let date: String
    let version: String
    let previousVersion: String
    let schema: Int
    let fingerprint: String
    let paths: InstallationPaths
    let previous: URL
    let staged: URL
    let recovery: URL
}

struct ManualUpdateRecovery: LocalizedError { var errorDescription: String? { "The app could not be quiesced. The server stays stopped and recovery is retained." } }

/// No database rollback: both directions require the same schema and preserve current data.
final class PairedInstallation {
    let files = FileManager.default
    let paths: InstallationPaths
    let serviceLabel: String
    let team: String
    let verify: (URL, String) throws -> Void
    let service: (String) throws -> Void
    let health: () throws -> Void
    let relaunch: (URL) throws -> Void
    init(paths: InstallationPaths, team: String, serviceLabel: String = "app.sumidoku.server",
         verify: @escaping (URL, String) throws -> Void = verifyReleaseBundle,
         service: @escaping (String) throws -> Void, health: @escaping () throws -> Void,
         relaunch: @escaping (URL) throws -> Void = { _ in }) {
        self.paths = paths; self.team = team; self.serviceLabel = serviceLabel; self.verify = verify
        self.service = service; self.health = health; self.relaunch = relaunch
    }
    static func info(_ app: URL) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { throw UpdateFailure("Invalid application metadata.") }
        return value
    }
    static func schema(_ config: URL) throws -> Int {
        let raw = try UpdateProcess.output("/usr/bin/sqlite3", ["-readonly", config.appendingPathComponent("sumidoku.db").path, "SELECT COALESCE(MAX(version),0) FROM _sqlx_migrations;"])
        guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { throw UpdateFailure("Unknown database schema; installation stopped.") }
        return value
    }
    static func fingerprint(_ config: URL) throws -> String {
        let db = config.appendingPathComponent("sumidoku.db").path
        guard try UpdateProcess.output("/usr/bin/sqlite3", ["-readonly", db, "PRAGMA integrity_check;"]) == "ok\n" else { throw UpdateFailure("Database integrity check failed.") }
        // Logical dumps exclude volatile SQL paging/WAL state. Include all durable user tables.
        let tables = ["_sqlx_migrations","user","manga","manga_user","chapter","chapter_user","category","category_manga","source","source_setting","source_repo","setting","auth_token","download","tracker_link"]
        let existing = Set(try UpdateProcess.output("/usr/bin/sqlite3", ["-readonly", db, "SELECT name FROM sqlite_master WHERE type='table';"]).split(separator: "\n").map(String.init))
        var bytes = Data()
        for table in tables where existing.contains(table) {
            bytes.append(Data(table.utf8))
            bytes.append(Data(try UpdateProcess.output("/usr/bin/sqlite3", ["-readonly", db, ".dump \(table)"]).utf8))
        }
        // Source packages, configuration and descriptors must also survive unchanged.
        for file in (FileManager.default.enumerator(at: config, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []).sorted(by: { $0.path < $1.path }) {
            let relative = String(file.path.dropFirst(config.path.count+1))
            if relative == "sumidoku.db" || relative.hasPrefix("sumidoku.db-") || relative.hasPrefix("logs/") || relative.hasPrefix("cache/") || relative.hasPrefix("covers/") { continue }
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                bytes.append(Data(relative.utf8)); bytes.append(Data(try updateDigest(file).utf8))
            }
        }
        return updateDigest(bytes)
    }
    func validatePaths() throws {
        let all = [paths.application,paths.config,paths.backups,paths.runtime,paths.agent,paths.runner]
        guard (1024...65535).contains(paths.port), Set(all.map { $0.standardizedFileURL.path }).count == all.count,
              all.allSatisfy({ $0.standardizedFileURL == $0.resolvingSymlinksInPath() }),
              !paths.backups.path.hasPrefix(paths.config.path + "/"), !paths.application.path.hasPrefix(paths.config.path + "/"),
              files.isWritableFile(atPath: paths.application.deletingLastPathComponent().path) else { throw UpdateFailure("Unsafe, overlapping or non-writable installation paths.") }
        let agent = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.agent), format: nil) as? [String: Any]
        guard agent?["Label"] as? String == serviceLabel,
              agent?["ProgramArguments"] as? [String] == ["/bin/bash",paths.runner.path,paths.config.path,paths.runtime.path],
              agent?["KeepAlive"] as? Bool == true else { throw UpdateFailure("The server is not the expected owned managed job. No service was changed.") }
        let config = try String(contentsOf: paths.config.appendingPathComponent("config.toml"), encoding: .utf8)
        var authSection = false
        for raw in config.components(separatedBy:.newlines) {
            let line = raw.trimmingCharacters(in:.whitespaces)
            if line.hasPrefix("[") {
                let header = String(line.split(separator:"#",maxSplits:1).first ?? "").filter { !$0.isWhitespace }
                guard !header.contains("\"") && !header.contains("'") else { throw UpdateFailure("Advanced TOML table names require configuration review before updating.") }
                authSection = header == "[auth]"
            }
            let key = String(line.split(separator:"=",maxSplits:1).first ?? "").filter { !$0.isWhitespace }
            if !line.hasPrefix("#") && (key.contains("\"") || key.contains("'")) { throw UpdateFailure("Advanced TOML keys require configuration review before updating.") }
            if ["auth","basic_password","auth.username","auth.password"].contains(key) || (authSection && ["username","password"].contains(key)) {
                throw UpdateFailure("A startup credential override requires account-maintenance review before updating. No credential or configuration was changed.")
            }
        }
        let lines = config.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("addr") }
        guard lines.count == 1, lines[0].range(of: "^\\s*addr\\s*=\\s*\"127\\.0\\.0\\.1:\(paths.port)\"\\s*(?:#.*)?$", options: .regularExpression) != nil else { throw UpdateFailure("The managed server must be bound to localhost.") }
    }
    func validate(_ app: URL, entry: DesktopCatalog.Entry) throws {
        try verify(app, team)
        let info = try Self.info(app)
        guard info["CFBundleIdentifier"] as? String == ReleaseIdentity.bundleIdentifier,
              info["CFBundleExecutable"] as? String == "Sumidoku",
              info["CFBundlePackageType"] as? String == "APPL",
              info["SumidokuCoordinatedUpdateProtocolVersion"] as? Int == 1,
              info["SumidokuReleaseVersion"] as? String == entry.version,
              info["CFBundleVersion"] as? String == String(entry.build),
              info["LSMinimumSystemVersion"] as? String == "13.0",
              try updateDigest(app.appendingPathComponent("Contents/MacOS/Sumidoku")) == entry.clientSha256,
              try updateDigest(app.appendingPathComponent("Contents/Resources/sumidoku-server")) == entry.serverSha256 else { throw UpdateFailure("The app/server pair does not match the authenticated release.") }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent("Contents/Resources/server-build.json"))) as? [String: Any]
        let installed = try JSONSerialization.jsonObject(with:Data(contentsOf:paths.application.appendingPathComponent("Contents/Resources/server-build.json"))) as? [String:Any]
        guard let feature = manifest?["featureSet"] as? String, !feature.isEmpty, feature == installed?["featureSet"] as? String else { throw UpdateFailure("The previous/current server feature-set compatibility is unknown.") }
        guard manifest?["variant"] as? String == "fork", manifest?["sourceRevision"] as? String == entry.sourceRevision,
              manifest?["sha256"] as? String == entry.serverSha256, manifest?["databaseSchemaVersion"] as? Int == entry.schema,
              try Self.schema(paths.config) == entry.schema else { throw UpdateFailure("This update/restore cannot safely read the current schema. No migration or database restore was attempted.") }
    }
    func record(_ journal: PairedJournal) throws {
        let data = try JSONEncoder().encode(journal)
        let url = journal.recovery.appendingPathComponent("update-journal.json")
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions:0o600], ofItemAtPath:url.path)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw UpdateFailure("Could not synchronize the update journal.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw UpdateFailure("Could not synchronize the update journal.") }
    }
    func recover(_ journal: inout PairedJournal) throws {
        try validatePaths()
        guard journal.paths == paths, UUID(uuidString: journal.id) != nil,
              journal.recovery.standardizedFileURL.path == paths.backups.appendingPathComponent("ApplicationUpdate-"+journal.id).standardizedFileURL.path,
              journal.previous.standardizedFileURL.path == paths.application.deletingLastPathComponent().appendingPathComponent(".Sumidoku-previous-"+journal.id+".app").standardizedFileURL.path,
              journal.staged.standardizedFileURL.path == paths.application.deletingLastPathComponent().appendingPathComponent(".Sumidoku-staged-"+journal.id+".app").standardizedFileURL.path else { throw UpdateFailure("Invalid recovery journal paths.") }
        let candidates = [journal.previous,journal.recovery.appendingPathComponent("PreviousClient.app"),paths.application]
        guard let prior = candidates.first(where: { app in
            guard let info = try? Self.info(app), (info["SumidokuReleaseVersion"] as? String ?? info["CFBundleShortVersionString"] as? String) == journal.previousVersion else { return false }
            return (try? verify(app,team)) != nil
        }) else { throw UpdateFailure("No authenticated previous application is available for recovery.") }
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:prior.appendingPathComponent("Contents/Resources/server-build.json"))) as? [String:Any]
        let oldServer = prior.appendingPathComponent("Contents/Resources/sumidoku-server")
        guard manifest?["sha256"] as? String == (try updateDigest(oldServer)), manifest?["databaseSchemaVersion"] as? Int == journal.schema else { throw UpdateFailure("The previous server does not match its authenticated application.") }
        try service("stop")
        guard try Self.schema(paths.config) == journal.schema,
              try Self.fingerprint(paths.config) == journal.fingerprint else {
            journal.phase = "manual-recovery-required-service-stopped"; try record(journal)
            throw UpdateFailure("Current data changed or is incompatible. Recovery is retained and the server stays stopped; no database was restored.")
        }
        // Use the sealed previous app's payload, not an unauthenticated loose runtime copy.
        try atomicRuntime(oldServer)
        if prior.standardizedFileURL.path != paths.application.standardizedFileURL.path {
            let restored = paths.application.deletingLastPathComponent().appendingPathComponent(".Sumidoku-recovery-"+UUID().uuidString+".app")
            try files.copyItem(at:prior,to:restored)
            guard renamex_np(restored.path,paths.application.path,UInt32(RENAME_SWAP)) == 0 else { throw UpdateFailure("The previous application could not be atomically restored.") }
            // Retain both sealed artifacts for recovery review.
        }
        if files.fileExists(atPath: journal.staged.path) { try files.removeItem(at: journal.staged) }
        try service("start"); try health()
        journal.phase = "failed-restored-without-database-rollback"; try record(journal)
    }
    private func atomicRuntime(_ source: URL) throws {
        let temp = paths.runtime.deletingLastPathComponent().appendingPathComponent(".sumidoku-update-" + UUID().uuidString)
        try files.copyItem(at: source, to: temp)
        try files.setAttributes([.posixPermissions:0o700],ofItemAtPath:temp.path)
        guard rename(temp.path,paths.runtime.path) == 0 else { try? files.removeItem(at: temp); throw UpdateFailure("Could not replace the managed server.") }
    }
    func apply(_ app: URL, entry: DesktopCatalog.Entry, restore: Bool = false, checkpoint: (String) throws -> Void = { _ in }) throws -> URL {
        try validatePaths(); try validate(app,entry:entry)
        let installed = try Self.info(paths.application)
        let oldVersion = installed["SumidokuReleaseVersion"] as? String ?? installed["CFBundleShortVersionString"] as? String ?? ""
        guard let old = AppVersion(oldVersion), let next = AppVersion(entry.version),
              restore ? (entry.channel == "stable" && old.prerelease != nil && next < old) : next > old else { throw UpdateFailure("Invalid update direction. Switching channels never downgrades an app.") }
        try verify(paths.application,team)
        let installedManifest = try JSONSerialization.jsonObject(with:Data(contentsOf:paths.application.appendingPathComponent("Contents/Resources/server-build.json"))) as? [String:Any]
        guard installedManifest?["sha256"] as? String == (try updateDigest(paths.runtime)) else { throw UpdateFailure("The installed app and managed runtime do not match. Resolve the existing installation before updating.") }
        let id = UUID().uuidString
        let recovery = paths.backups.appendingPathComponent("ApplicationUpdate-"+id)
        try files.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        var journal = PairedJournal(phase:"preparing",id:id,date:ISO8601DateFormatter().string(from:Date()),version:entry.version,previousVersion:oldVersion,schema:entry.schema,fingerprint:try Self.fingerprint(paths.config),paths:paths,
            previous:paths.application.deletingLastPathComponent().appendingPathComponent(".Sumidoku-previous-"+id+".app"),staged:paths.application.deletingLastPathComponent().appendingPathComponent(".Sumidoku-staged-"+id+".app"),recovery:recovery)
        try record(journal)
        try service("stop")
        do {
            // Record again after graceful stop, then take a cold recovery snapshot.
            journal = PairedJournal(phase:"server-stopped",id:journal.id,date:journal.date,version:journal.version,previousVersion:journal.previousVersion,schema:journal.schema,fingerprint:try Self.fingerprint(paths.config),paths:paths,previous:journal.previous,staged:journal.staged,recovery:recovery)
            try record(journal); try checkpoint(journal.phase)
            try files.copyItem(at:paths.config,to:recovery.appendingPathComponent("Server"))
            guard try Self.fingerprint(recovery.appendingPathComponent("Server")) == journal.fingerprint else { throw UpdateFailure("Cold recovery snapshot verification failed.") }
            try files.copyItem(at:paths.application,to:recovery.appendingPathComponent("PreviousClient.app"))
            try files.copyItem(at:paths.application,to:journal.previous)
            try files.copyItem(at:paths.runtime,to:recovery.appendingPathComponent("previous-server"))
            try files.copyItem(at:paths.agent,to:recovery.appendingPathComponent("LaunchAgent.plist"))
            try files.copyItem(at:app,to:journal.staged); try validate(journal.staged,entry:entry)
            journal.phase = "snapshot-verified"; try record(journal); try checkpoint(journal.phase)
            // Journal intent BEFORE each mutation, enabling interruption recovery.
            journal.phase = "replacing-pair"; try record(journal)
            try atomicRuntime(app.appendingPathComponent("Contents/Resources/sumidoku-server"))
            try checkpoint("runtime-replaced")
            guard renamex_np(journal.staged.path, paths.application.path, UInt32(RENAME_SWAP)) == 0 else { throw UpdateFailure("The application could not be atomically replaced.") }
            journal.phase = "artifacts-replaced"; try record(journal); try checkpoint(journal.phase)
            try service("start"); try health()
            guard try Self.schema(paths.config) == entry.schema, try Self.fingerprint(paths.config) == journal.fingerprint else { throw UpdateFailure("Data integrity changed during the handoff.") }
            try relaunch(recovery)
            journal.phase = "verified"; try record(journal)
            // Retain the previous app and recovery copy; no pruning of user backups.
            return recovery
        } catch {
            let original = error
            if error is ManualUpdateRecovery {
                try service("stop")
                journal.phase = "manual-recovery-required-service-stopped"; try record(journal)
                throw original
            }
            try recover(&journal)
            throw original
        }
    }
}

func verifyDeveloperRelease(_ app: URL, _ team: String) throws {
    guard team.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil else { throw UpdateFailure("A trusted Developer ID team is required.") }
    try UpdateProcess.run("/usr/bin/codesign",["--verify","--deep","--strict",app.path])
    // codesign metadata goes to stderr; use a requirement to bind identifier, team and Apple anchor.
    let requirement = "anchor apple generic and identifier \"app.sumidoku.desktop\" and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    try UpdateProcess.run("/usr/bin/codesign",["--verify","--strict","-R",requirement,app.path])
    try UpdateProcess.run("/usr/sbin/spctl",["--assess","--type","execute",app.path])
    for path in ["Contents/MacOS/Sumidoku","Contents/Resources/sumidoku-server","Contents/MacOS/SumidokuUpdateHelper"] where FileManager.default.fileExists(atPath: app.appendingPathComponent(path).path) {
        let header = try Data(contentsOf: app.appendingPathComponent(path), options: .mappedIfSafe).prefix(8)
        guard Array(header) == [0xcf,0xfa,0xed,0xfe,0x0c,0x00,0x00,0x01] else { throw UpdateFailure("The release requires an arm64 executable.") }
    }
}
