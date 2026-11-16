import Foundation
import CryptoKit
import Darwin

@main
struct ReleaseSecurityTests {
    static var assertions = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw UpdateFailure("FAIL: " + name) }
        assertions += 1; print("PASS: " + name); fflush(stdout)
    }
    static func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { assertions += 1; print("PASS: rejected " + name + " (" + error.localizedDescription + ")"); fflush(stdout); return }
        throw UpdateFailure("FAIL: accepted " + name)
    }
    final class Fixture {
        let root: URL
        let paths: InstallationPaths
        let key = Curve25519.Signing.PrivateKey()
        var events = [String]()
        var beta: URL!
        var stable: URL!
        var betaEntry: DesktopCatalog.Entry!
        var stableEntry: DesktopCatalog.Entry!
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sumidoku-release-security-"+UUID().uuidString).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            for name in ["Server","Backups","bin","incoming"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false) }
            paths = InstallationPaths(application:root.appendingPathComponent("Sumidoku.app"),config:root.appendingPathComponent("Server"),backups:root.appendingPathComponent("Backups"),runtime:root.appendingPathComponent("bin/server"),agent:root.appendingPathComponent("agent.plist"),runner:root.appendingPathComponent("bin/runner.sh"),port:3349)
            try Data("addr = \"127.0.0.1:3349\"\n".utf8).write(to:paths.config.appendingPathComponent("config.toml"))
            try Data("source-package".utf8).write(to:paths.config.appendingPathComponent("source.aix"))
            try UpdateProcess.run("/usr/bin/sqlite3",[paths.config.appendingPathComponent("sumidoku.db").path,"CREATE TABLE _sqlx_migrations(version INTEGER); INSERT INTO _sqlx_migrations VALUES(37); CREATE TABLE user(id INTEGER,value TEXT); INSERT INTO user VALUES(1,'fixture-hash'); CREATE TABLE chapter_user(id INTEGER,progress INTEGER); INSERT INTO chapter_user VALUES(1,5); CREATE TABLE setting(key TEXT,value TEXT); INSERT INTO setting VALUES('backup.enabled','true');"])
            try PropertyListSerialization.data(fromPropertyList:["Label":"app.sumidoku.server","KeepAlive":true,"ProgramArguments":["/bin/bash",paths.runner.path,paths.config.path,paths.runtime.path]],format:.xml,options:0).write(to:paths.agent)
            try Data("runner".utf8).write(to:paths.runner)
            (stable,stableEntry) = try make("Stable","1.3.0",6,"old-server")
            (beta,betaEntry) = try make("Beta","1.3.1-beta.1",8,"beta-server")
            try FileManager.default.copyItem(at:stable,to:paths.application)
            try Data("old-server".utf8).write(to:paths.runtime)
        }
        func make(_ name: String, _ version: String, _ build: Int, _ server: String) throws -> (URL,DesktopCatalog.Entry) {
            let directory = root.appendingPathComponent("incoming/"+name)
            let app = directory.appendingPathComponent("Sumidoku.app")
            try FileManager.default.createDirectory(at:app.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:app.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:false)
            try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"app.sumidoku.desktop","CFBundleExecutable":"Sumidoku","CFBundlePackageType":"APPL","SumidokuCoordinatedUpdateProtocolVersion":1,"CFBundleVersion":String(build),"CFBundleShortVersionString":String(version.split(separator:"-")[0]),"SumidokuReleaseVersion":version,"LSMinimumSystemVersion":"13.0"],format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
            try Data(("client-"+version).utf8).write(to:app.appendingPathComponent("Contents/MacOS/Sumidoku"))
            try Data(server.utf8).write(to:app.appendingPathComponent("Contents/Resources/sumidoku-server"))
            let serverHash = try updateDigest(app.appendingPathComponent("Contents/Resources/sumidoku-server"))
            try JSONSerialization.data(withJSONObject:["variant":"fork","featureSet":"source-integrations-v1","sha256":serverHash,"databaseSchemaVersion":37,"sourceRevision":String(repeating:"a",count:40)]).write(to:app.appendingPathComponent("Contents/Resources/server-build.json"))
            let archive = directory.appendingPathComponent("archive.zip")
            try UpdateProcess.run("/usr/bin/ditto",["-c","-k","--norsrc","--noextattr","--keepParent",app.path,archive.path])
            let bytes = try Data(contentsOf:archive)
            let entry = DesktopCatalog.Entry(version:version,build:build,channel:version.contains("beta") ? "beta" : "stable",url:URL(string:"https://github.com/TTokomon/SumidokuApp/releases/download/desktop-v\(version)/Sumidoku-Desktop-\(version)-macOS-arm64.zip")!,length:bytes.count,signature:try key.signature(for:bytes).base64EncodedString(),sha256:updateDigest(bytes),clientSha256:try updateDigest(app.appendingPathComponent("Contents/MacOS/Sumidoku")),serverSha256:serverHash,sourceRevision:String(repeating:"a",count:40),schema:37)
            return (app,entry)
        }
        func transaction(health: @escaping () throws -> Void = {}) -> PairedInstallation {
            PairedInstallation(paths:paths,team:"ABCDEFGHIJ",verify:{ _,_ in },service:{ self.events.append($0) },health:health,relaunch:{ _ in self.events.append("relaunch") })
        }
        func cleanup() { try? FileManager.default.removeItem(at:root) }
    }
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n",stderr); exit(1) }
    }
    static func run() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--interrupt" {
            let root = URL(fileURLWithPath:CommandLine.arguments[2]).resolvingSymlinksInPath()
            guard root.lastPathComponent.hasPrefix("sumidoku-release-security-") else { throw UpdateFailure("Fixture root required.") }
            let paths = try JSONDecoder().decode(InstallationPaths.self,from:Data(contentsOf:root.appendingPathComponent("paths.json")))
            let entry = try JSONDecoder().decode(DesktopCatalog.Entry.self,from:Data(contentsOf:root.appendingPathComponent("beta.json")))
            let tx = PairedInstallation(paths:paths,team:"ABCDEFGHIJ",verify:{ _,_ in },service:{ _ in },health:{})
            _ = try tx.apply(root.appendingPathComponent("incoming/Beta/Sumidoku.app"),entry:entry,checkpoint:{ if $0 == "runtime-replaced" { _exit(73) } })
            throw UpdateFailure("Interruption checkpoint did not execute.")
        }
        let f = try Fixture(); defer { f.cleanup() }
        let catalogBytes = try JSONEncoder().encode(DesktopCatalog(format:1,releases:[f.stableEntry,f.betaEntry]))
        let signature = try f.key.signature(for:catalogBytes)
        let catalog = try DesktopCatalog.authenticated(catalogBytes,signature:signature,key:f.key.publicKey.rawRepresentation)
        try expect(catalog.latest(channel:.stable)?.version == "1.3.0","Stable excludes Beta")
        try expect(catalog.latest(channel:.prerelease)?.version == "1.3.1-beta.1","Beta opt-in includes Stable and Beta")
        try reject("tampered catalog") { _ = try DesktopCatalog.authenticated(catalogBytes+Data([32]),signature:signature,key:f.key.publicKey.rawRepresentation) }
        try reject("wrong feed key") { _ = try DesktopCatalog.authenticated(catalogBytes,signature:signature,key:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) }
        let trust = DistributionPolicy(info:["SUFeedURL":"https://example.invalid/appcast.xml","SumidokuReleaseCatalogURL":"https://example.invalid/catalog.json","SUPublicEDKey":f.key.publicKey.rawRepresentation.base64EncodedString(),"SumidokuReleaseTeam":"ABCDEFGHIJ","SumidokuCoordinatedUpdatesValidated":true])
        let fetched = try await AuthenticatedCatalog.fetch(policy:trust,download:{ url,_ in url.path.hasSuffix(".sig") ? Data(signature.base64EncodedString().utf8) : catalogBytes })
        try expect(fetched.value.releases.count == 2,"transport catalog authenticated before use")
        do { _ = try await AuthenticatedCatalog.fetch(policy:trust,download:{ _,_ in throw URLError(.notConnectedToInternet) }); throw UpdateFailure("FAIL: offline catalog accepted") }
        catch is URLError { assertions += 1; print("PASS: offline catalog fails before installation") }
        let delegate = BoundedReleaseDownload(limit:1024,hosts:["github.com"])
        let urlSession = URLSession(configuration:.ephemeral)
        defer { urlSession.invalidateAndCancel() }
        let response = HTTPURLResponse(url:URL(string:"https://github.com/file")!,statusCode:302,httpVersion:nil,headerFields:nil)!
        for url in ["http://github.com/file","https://evil.invalid/file","https://github.com:444/file","https://owner:pass@github.com/file"] {
            var accepted: URLRequest?
            let task = urlSession.dataTask(with:response.url!)
            delegate.urlSession(urlSession,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:url)!),completionHandler:{ accepted = $0 })
            try expect(accepted == nil,"unsafe release redirect rejected")
        }
        let archive = f.beta.deletingLastPathComponent().appendingPathComponent("archive.zip")
        let extracted = try ReleaseArchive.extract(archive,entry:f.betaEntry,key:f.key.publicKey.rawRepresentation,to:f.root.appendingPathComponent("unpacked"))
        try expect(try updateDigest(extracted.appendingPathComponent("Contents/MacOS/Sumidoku")) == f.betaEntry.clientSha256,"authenticated archive extracted exact client")
        try reject("corrupt archive") {
            let corrupt=f.root.appendingPathComponent("corrupt.zip");try (Data(contentsOf:archive)+Data([1])).write(to:corrupt)
            _ = try ReleaseArchive.extract(corrupt,entry:f.betaEntry,key:f.key.publicKey.rawRepresentation,to:f.root.appendingPathComponent("bad"))
        }
        try reject("wrong archive key") { _ = try ReleaseArchive.extract(archive,entry:f.betaEntry,key:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,to:f.root.appendingPathComponent("wrong")) }
        try reject("truncated ZIP") { try ReleaseArchive.inspect(Data([0,1,2]),archive:archive) }
        for kind in ["traversal","absolute","duplicate","symlink-escape","symlink-ancestor","local-mismatch","bomb"] {
            let bad = f.root.appendingPathComponent(kind+".zip")
            let script = """
            import sys,zipfile,stat,struct,warnings
            warnings.simplefilter('ignore')
            path,kind=sys.argv[1:]
            with zipfile.ZipFile(path,'w') as z:
                if kind=='traversal':z.writestr('Sumidoku.app/../../escape',b'x')
                elif kind=='absolute':z.writestr('/escape',b'x')
                elif kind=='duplicate':z.writestr('Sumidoku.app/Case',b'x');z.writestr('Sumidoku.app/case',b'y')
                elif kind.startswith('symlink'):
                    i=zipfile.ZipInfo('Sumidoku.app/link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16
                    z.writestr(i,'../../escape' if kind=='symlink-escape' else 'Resources')
                    if kind=='symlink-ancestor':z.writestr('Sumidoku.app/link/escape',b'x')
                else:z.writestr('Sumidoku.app/Good',b'x')
            if kind in ['local-mismatch','bomb']:
                b=bytearray(open(path,'rb').read())
                if kind=='local-mismatch':b[30:47]=b'Sumidoku.app/Evil'
                else:struct.pack_into('<I',b,b.index(b'PK\\x01\\x02')+24,0x70000000)
                open(path,'wb').write(b)
            """
            try UpdateProcess.run("/usr/bin/python3",["-c",script,bad.path,kind])
            let bytes = try Data(contentsOf:bad)
            var raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(f.betaEntry)) as! [String:Any]
            raw["length"] = bytes.count; raw["sha256"] = updateDigest(bytes); raw["signature"] = try f.key.signature(for:bytes).base64EncodedString()
            let entry = try JSONDecoder().decode(DesktopCatalog.Entry.self,from:JSONSerialization.data(withJSONObject:raw))
            let output = f.root.appendingPathComponent("reject-"+kind)
            try reject("authenticated malicious archive "+kind) { _ = try ReleaseArchive.extract(bad,entry:entry,key:f.key.publicKey.rawRepresentation,to:output) }
            try expect(!FileManager.default.fileExists(atPath:output.path),"rejected archive created no extraction directory")
        }
        try reject("production unsigned/wrong signing identity") { try verifyDeveloperRelease(f.beta,"ABCDEFGHIJ") }
        let before = try PairedInstallation.fingerprint(f.paths.config)
        _ = try f.transaction().apply(f.beta,entry:f.betaEntry)
        try expect(try String(contentsOf:f.paths.runtime,encoding:.utf8) == "beta-server","paired server upgraded")
        try expect(f.events == ["stop","start","relaunch"],"one stop/start and explicit app relaunch")
        try expect(try PairedInstallation.fingerprint(f.paths.config) == before,"credentials, progress, settings and packages preserved")
        try UpdateProcess.run("/usr/bin/sqlite3",[f.paths.config.appendingPathComponent("sumidoku.db").path,"UPDATE chapter_user SET progress=9;"])
        let afterReading = try PairedInstallation.fingerprint(f.paths.config)
        try reject("channel switch is not downgrade permission") { _ = try f.transaction().apply(f.stable,entry:f.stableEntry) }
        _ = try f.transaction().apply(f.stable,entry:f.stableEntry,restore:true)
        try expect(try PairedInstallation.fingerprint(f.paths.config) == afterReading,"Restore Stable preserves progress made on Beta")
        try expect(try String(contentsOf:f.paths.runtime,encoding:.utf8) == "old-server","matching Stable server restored")
        try expect(try PairedInstallation.info(f.paths.application)["SumidokuReleaseVersion"] as? String == "1.3.0","Stable application restored")
        let recovery = try FileManager.default.contentsOfDirectory(at:f.paths.backups,includingPropertiesForKeys:nil)
        try expect(recovery.count == 2,"both cold recovery snapshots retained")
        try expect(try recovery.allSatisfy { try JSONDecoder().decode(PairedJournal.self,from:Data(contentsOf:$0.appendingPathComponent("update-journal.json"))).phase == "verified" },"recoverable journals record verified pairs")
        let failure = try Fixture();defer { failure.cleanup() }
        try reject("failed server/login handoff") {
            _ = try failure.transaction(health:{ if try String(contentsOf:failure.paths.runtime,encoding:.utf8) == "beta-server" { throw UpdateFailure("fixture failure") } }).apply(failure.beta,entry:failure.betaEntry)
        }
        try expect(try String(contentsOf:failure.paths.runtime,encoding:.utf8) == "old-server","failed handoff restored original runtime")
        try expect(try PairedInstallation.info(failure.paths.application)["SumidokuReleaseVersion"] as? String == "1.3.0","failed handoff restored original client")
        let interrupted = try Fixture();defer { interrupted.cleanup() }
        let journalURL = try interrupted.transaction().apply(interrupted.beta,entry:interrupted.betaEntry).appendingPathComponent("update-journal.json")
        var journal = try JSONDecoder().decode(PairedJournal.self,from:Data(contentsOf:journalURL));journal.phase="artifacts-replaced"
        try interrupted.transaction().record(journal)
        try interrupted.transaction().recover(&journal)
        try expect(try String(contentsOf:interrupted.paths.runtime,encoding:.utf8) == "old-server","persisted interruption journal recovered pair")
        let incompatible = try Fixture();defer { incompatible.cleanup() }
        _ = try incompatible.transaction().apply(incompatible.beta,entry:incompatible.betaEntry)
        try UpdateProcess.run("/usr/bin/sqlite3",[incompatible.paths.config.appendingPathComponent("sumidoku.db").path,"INSERT INTO _sqlx_migrations VALUES(38);"])
        let oldEvents = incompatible.events.count
        try reject("incompatible Stable schema") { _ = try incompatible.transaction().apply(incompatible.stable,entry:incompatible.stableEntry,restore:true) }
        try expect(incompatible.events.count == oldEvents,"incompatible restore rejected before stopping")
        let seeded = try Fixture();defer { seeded.cleanup() }
        try Data("addr = \"127.0.0.1:3349\"\n[auth]\npassword = \"fixture-only\"\n".utf8).write(to:seeded.paths.config.appendingPathComponent("config.toml"))
        try reject("startup credential override") { _ = try seeded.transaction().apply(seeded.beta,entry:seeded.betaEntry) }
        try expect(seeded.events.isEmpty,"credential override rejected before any service mutation")
        let hard = try Fixture();defer { hard.cleanup() }
        try JSONEncoder().encode(hard.paths).write(to:hard.root.appendingPathComponent("paths.json"))
        try JSONEncoder().encode(hard.betaEntry).write(to:hard.root.appendingPathComponent("beta.json"))
        let child = Process();child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments = ["--interrupt",hard.root.path]
        child.standardOutput = FileHandle.nullDevice;child.standardError = FileHandle.nullDevice
        try child.run();child.waitUntilExit()
        try expect(child.terminationStatus == 73,"helper process interrupted between runtime replacement and app swap")
        let interruptedFolder = try FileManager.default.contentsOfDirectory(at:hard.paths.backups,includingPropertiesForKeys:nil).first!
        var interruptedJournal = try JSONDecoder().decode(PairedJournal.self,from:Data(contentsOf:interruptedFolder.appendingPathComponent("update-journal.json")))
        try Data("tampered-loose-copy".utf8).write(to:interruptedFolder.appendingPathComponent("previous-server"))
        try hard.transaction().recover(&interruptedJournal)
        try expect(try String(contentsOf:hard.paths.runtime,encoding:.utf8) == "old-server","hard interruption restored sealed previous runtime, ignoring tampered loose copy")
        let changed = try Fixture();defer { changed.cleanup() }
        let changedFolder = try changed.transaction().apply(changed.beta,entry:changed.betaEntry)
        try UpdateProcess.run("/usr/bin/sqlite3",[changed.paths.config.appendingPathComponent("sumidoku.db").path,"UPDATE chapter_user SET progress=12;"])
        var changedJournal = try JSONDecoder().decode(PairedJournal.self,from:Data(contentsOf:changedFolder.appendingPathComponent("update-journal.json")))
        try reject("changed data during interrupted recovery") { try changed.transaction().recover(&changedJournal) }
        try expect(changedJournal.phase == "manual-recovery-required-service-stopped","changed data remains stopped for review rather than rewound")
        try expect(try UpdateProcess.output("/usr/bin/sqlite3",[changed.paths.config.appendingPathComponent("sumidoku.db").path,"SELECT progress FROM chapter_user;"]) == "12\n","new reading progress retained after refused recovery")
        print("PASS: \(assertions) release security and disposable Stable/Beta/Stable transaction assertions; Developer ID success path remains a separate signed gate")
    }
}
