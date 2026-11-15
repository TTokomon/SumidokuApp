import AppKit
import Foundation

struct StubReleases: ReleaseFetching {
    let data: Data
    var code = 200
    var offline = false
    var delay: UInt64 = 0
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if offline { throw URLError(.notConnectedToInternet) }
        return (data,HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["ETag":"fixture-version"])!)
    }
}
@main
@MainActor
struct UpdatePolicyTests {
    static var count = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ name: String) {
        guard (try? value()) == true else { fputs("FAIL: \(name)\n",stderr); exit(1) }; count += 1; print("PASS: \(name)")
    }
    static func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, archive: String = "Sumidoku-Desktop-fixture-macOS-arm64.zip") -> DesktopRelease {
        try! JSONDecoder().decode(DesktopRelease.self,from:JSONSerialization.data(withJSONObject:["id":Int.random(in:1...1000000),"tag_name":tag,"name":tag,"body":"Fixture release notes","html_url":"https://github.com/TTokomon/SumidokuApp/releases/tag/fixture","draft":draft,"prerelease":prerelease,"assets":[["name":archive,"browser_download_url":"https://github.com/TTokomon/SumidokuApp/releases/download/fixture/update.zip"]]]))
    }
    static func main() async throws {
        expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!, "numeric versions are not compared lexically")
        expect(AppVersion("1.3.0")! > AppVersion("1.3.0-beta.9")!, "stable sorts after its prerelease")
        expect(AppVersion("1.3.0-beta.10")! > AppVersion("1.3.0-beta.2")!, "numeric prerelease components")
        for bad in ["", "main", "v", "-beta", "1.x.0", "1.2.3.4"] { expect(AppVersion(bad)==nil,"reject invalid version \(bad)") }
        expect(try ReleaseSelection.evaluate([release("1.3.0")],installed:"1.3.0",channel:.stable,developmentBuild:true).state == .unavailable,"local development build never falsely claims published current status")
        let old = release("1.2.0"), current = release("1.3.0"), newer = release("1.4.0"), beta = release("1.5.0-beta.1",prerelease:true)
        expect(try ReleaseSelection.evaluate([current],installed:"1.3.0",channel:.stable).state == .current,"green requires successful matching-version check")
        expect(try ReleaseSelection.evaluate([newer],installed:"1.3.0",channel:.stable).state == .available,"newer release is orange")
        expect(try ReleaseSelection.evaluate([old],installed:"1.3.0",channel:.stable).state == .unavailable,"unreleased development version is never green")
        expect(try ReleaseSelection.evaluate([],installed:"1.3.0",channel:.stable).state == .unavailable,"empty public release catalog is gray")
        expect(try ReleaseSelection.evaluate([beta,current],installed:"1.3.0",channel:.stable).latest?.tag_name == "1.3.0","stable channel excludes prereleases")
        expect(try ReleaseSelection.evaluate([beta,current],installed:"1.3.0",channel:.prerelease).latest?.tag_name == beta.tag_name,"prerelease channel is explicit")
        expect(try ReleaseSelection.evaluate([release("9.0.0",draft:true)],installed:"1.3.0",channel:.stable).history.isEmpty,"drafts never become updates")
        expect(try ReleaseSelection.evaluate([release("9.0.0",archive:"sumidoku-server.zip")],installed:"1.3.0",channel:.stable).history.isEmpty,"server-only releases cannot replace the app")
        expect(try ReleaseSelection.evaluate([release("9.0.0",archive:"Sumidoku-Desktop-9-macOS-x86_64.zip")],installed:"1.3.0",channel:.stable).history.isEmpty,"incompatible architecture is excluded")
        expect(!DistributionPolicy(info:[:]).provisioned,"unsigned/unprovisioned installation is blocked")
        let key = Data(repeating:1,count:32).base64EncodedString()
        for feed in ["http://example.com/feed.xml","https:/broken","https://user:secret@example.com/feed.xml"] {
            expect(!DistributionPolicy(info:["SUFeedURL":feed,"SUPublicEDKey":key,"SumidokuReleaseTeam":"ABCDEFGHIJ","SumidokuCoordinatedUpdatesValidated":true]).provisioned,"reject unsafe feed")
        }
        expect(SurfacePolicy.material(majorVersion:26,reduceTransparency:false,increasedContrast:false) == .liquidGlass,"macOS 26 uses actual native glass")
        expect(SurfacePolicy.material(majorVersion:25,reduceTransparency:false,increasedContrast:false) == .systemMaterial,"older macOS uses native system material")
        expect(SurfacePolicy.material(majorVersion:26,reduceTransparency:true,increasedContrast:false) == .opaque,"reduce transparency requests opaque native surfaces")
        expect(SurfacePolicy.material(majorVersion:26,reduceTransparency:false,increasedContrast:true) == .opaque,"increased contrast requests opaque native surfaces")
        let suite = "SumidokuUpdateTests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        func bytes(_ release: DesktopRelease) throws -> Data {
            try JSONSerialization.data(withJSONObject:[["id":release.id,"tag_name":release.tag_name,"name":release.name!,"body":"Notes","html_url":release.html_url,"draft":false,"prerelease":false,"assets":[["name":release.desktopArchive!.name,"browser_download_url":release.desktopArchive!.browser_download_url]]]])
        }
        let updates=AppUpdates(defaults:defaults,schedule:false,fetcher:StubReleases(data:try bytes(newer)))
        expect(updates.state == .notChecked,"initial status is gray, never falsely green")
        updates.check(); await updates.waitForCheck()
        expect(updates.state == .available,"manual check transitions to update available")
        expect(!updates.canInstall,"development build cannot perform a GUI-only install")
        updates.install();expect(updates.detail.contains("not enabled"),"blocked installation explains missing distribution contract")
        let offline=AppUpdates(defaults:defaults,schedule:false,fetcher:StubReleases(data:Data(),offline:true))
        offline.check();await offline.waitForCheck();expect(offline.state == .offline,"offline is gray rather than a false update error")
        let malformed=AppUpdates(defaults:defaults,schedule:false,fetcher:StubReleases(data:Data("invalid".utf8)))
        malformed.check();await malformed.waitForCheck();expect(malformed.state == .error,"malformed release information is a real error")
        let cancel=AppUpdates(defaults:defaults,schedule:false,fetcher:StubReleases(data:Data(),delay:1_000_000_000))
        cancel.check();cancel.cancel();expect(cancel.state == .notChecked,"cancel preserves the installed application and resets unknown status")
        defaults.removeObject(forKey:"desktop.lastUpdateAttempt")
        let automatic=AppUpdates(defaults:defaults,schedule:false,fetcher:StubReleases(data:try bytes(current)))
        automatic.automaticChecks=false;automatic.checkIfDue();expect(automatic.state == .notChecked,"automatic checking respects opt out")
        automatic.automaticChecks=true;automatic.checkIfDue();await automatic.waitForCheck();expect(automatic.state == .current,"optional automatic check uses same validated catalog path")
        automatic.checkIfDue();expect(automatic.state == .current,"daily polling does not constantly refetch")
        print("PASS: \(count) update/navigation-material policy assertions; fixture transport only")
    }
}
