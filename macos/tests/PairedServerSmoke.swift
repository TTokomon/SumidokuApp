import Foundation
import Darwin

/// Test-only driver: real disposable launchd/server, fixture client executable and signing verifier.
@main
struct PairedServerSmoke {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n",stderr); exit(1) }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 3 else { throw UpdateFailure("Expected disposable root and fixture job label.") }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        let label = CommandLine.arguments[2]
        guard root.lastPathComponent.hasPrefix("sumidoku-paired-smoke-"), label.hasPrefix("app.sumidoku.fixture.") else { throw UpdateFailure("Only disposable fixture paths/jobs are allowed.") }
        let paths = try JSONDecoder().decode(InstallationPaths.self,from:Data(contentsOf:root.appendingPathComponent("paths.json")))
        guard paths.port != 3000, [paths.application,paths.config,paths.backups,paths.runtime,paths.agent,paths.runner].allSatisfy({ $0.path.hasPrefix(root.path+"/") }) else { throw UpdateFailure("Fixture attempted to escape its installation.") }
        let session = try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [String:String]
        let api = LocalAPI(port:paths.port)
        let cookie = LocalAPI.cookieHeader(try api.login(username:session["username"]!,password:session["password"]!).cookies)
        let domain = "gui/\(getuid())"
        func wait(_ running: Bool) throws {
            for _ in 0..<150 {
                let status = (try? api.request("health").response.statusCode) == 200
                if status == running { return }
                Thread.sleep(forTimeInterval:0.1)
            }
            throw UpdateFailure("Fixture service readiness timeout.")
        }
        let transaction = PairedInstallation(paths:paths,team:"ABCDEFGHIJ",serviceLabel:label,verify:{ app,_ in
            guard app.resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else { throw UpdateFailure("Foreign test bundle.") }
        },service:{ action in
            if action == "stop" {
                _ = try? UpdateProcess.output("/bin/launchctl",["bootout",domain+"/"+label]);try wait(false)
            } else {
                var started = false
                for _ in 0..<50 {
                    if (try? UpdateProcess.output("/bin/launchctl",["bootstrap",domain,paths.agent.path])) != nil { started = true; break }
                    Thread.sleep(forTimeInterval:0.1)
                }
                guard started else { throw UpdateFailure("Fixture bootstrap failed.") };try wait(true)
            }
        },health:{
            guard try api.request("api/v1/auth/status",cookie:cookie).json["username"] as? String == session["username"] else { throw UpdateFailure("Preserved fixture authentication failed.") }
            let listeners = try UpdateProcess.output("/usr/sbin/lsof",["-nP","-tiTCP:\(paths.port)","-sTCP:LISTEN"]).split(separator:"\n")
            guard listeners.count == 1 else { throw UpdateFailure("Duplicate fixture server listener.") }
        },relaunch:{ _ in try UpdateProcess.run(paths.application.appendingPathComponent("Contents/MacOS/Sumidoku").path,[]) })
        let beta = try JSONDecoder().decode(DesktopCatalog.Entry.self,from:Data(contentsOf:root.appendingPathComponent("beta.json")))
        let stable = try JSONDecoder().decode(DesktopCatalog.Entry.self,from:Data(contentsOf:root.appendingPathComponent("stable.json")))
        func reading() throws -> Data {
            let value = try api.request("api/v1/backups/document",cookie:cookie).json
            return try JSONSerialization.data(withJSONObject:["library":value["library"] ?? [],"progress":value["progress"] ?? []],options:.sortedKeys)
        }
        let originalReading = try reading()
        let recovery = try transaction.apply(root.appendingPathComponent("Beta/Sumidoku.app"),entry:beta)
        let before = try JSONDecoder().decode(PairedJournal.self,from:Data(contentsOf:recovery.appendingPathComponent("update-journal.json"))).fingerprint
        guard try reading() == originalReading else { throw UpdateFailure("Reading state changed on Beta.") }
        guard try PairedInstallation.fingerprint(paths.config) == before else { throw UpdateFailure("Beta changed fixture data.") }
        _ = try transaction.apply(root.appendingPathComponent("Stable/Sumidoku.app"),entry:stable,restore:true)
        guard try PairedInstallation.fingerprint(paths.config) == before else { throw UpdateFailure("Restore changed fixture data.") }
        guard try reading() == originalReading else { throw UpdateFailure("Reading state changed on Stable restore.") }
        let launches = try String(contentsOf:root.appendingPathComponent("client-launches.log"),encoding:.utf8)
        guard launches == "1.3.1-beta.1\n1.3.0\n" else { throw UpdateFailure("Wrong fixture client relaunched.") }
        print("PASS: actual disposable launchd Stable → Beta → Stable; matching servers restarted, one listener, login/library/progress/config/packages preserved; fixture clients relaunched. Public signed GUI handoff is not certified.")
    }
}
