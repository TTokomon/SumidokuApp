import AppKit
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

protocol ReleaseFetching {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
struct LiveReleaseClient: ReleaseFetching {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if COMMUNITY_E2E
        let bytes = try Data(contentsOf:URL(fileURLWithPath:ReleaseIdentity.fixtureRoot!).appendingPathComponent("releases.json"))
        return (bytes,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        #else
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ReleaseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateFailure("The release service returned an invalid response.") }
        return (data,http)
        #endif
    }
}

struct InstalledUpdateRecord: Identifiable {
    let id: String
    let version: String
    let phase: String
    let date: String
}

@MainActor
final class AppUpdates: NSObject, ObservableObject {
    @Published private(set) var state: AppUpdateState = .notChecked
    @Published private(set) var detail = "No application update check has completed."
    @Published private(set) var history: [DesktopRelease] = []
    @Published private(set) var latest: DesktopRelease?
    @Published private(set) var installedHistory: [InstalledUpdateRecord] = []
    @Published private(set) var lastChecked: Date?
    @Published var channel: UpdateChannel { didSet { defaults.set(channel.rawValue, forKey: "desktop.updateChannel"); cancel(); latest = nil; history = [] } }
    @Published var automaticChecks: Bool { didSet { defaults.set(automaticChecks, forKey: "desktop.automaticChecks") } }
    @Published var automaticInstallation: Bool = false
    var installer: NativeUpdateInstaller?
    @Published private(set) var installationReady = false
    @Published private(set) var stableRestoreVersion: String?
    @Published private(set) var installing = false
    @Published private(set) var pendingRecovery = false
    var canInstall: Bool { policy.provisioned && installationReady && !installing && !pendingRecovery }
    var canRestoreStable: Bool { canInstall && stableRestoreVersion != nil && AppVersion(installed)?.prerelease != nil }
    let developmentBuild: Bool
    let installed: String
    let policy: DistributionPolicy
    private let defaults: UserDefaults
    private let fetcher: ReleaseFetching
    private var checkTask: Task<Void, Never>?
    private var generation = 0
    private var timer: Timer?
    init(bundle: Bundle = .main, defaults: UserDefaults = .standard, schedule: Bool = true, fetcher: ReleaseFetching = LiveReleaseClient()) {
        self.defaults = defaults
        self.fetcher = fetcher
        installed = bundle.object(forInfoDictionaryKey: "SumidokuReleaseVersion") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
        developmentBuild = bundle.object(forInfoDictionaryKey: "SumidokuDevelopmentBuild") as? Bool ?? false
        policy = DistributionPolicy(info: bundle.infoDictionary ?? [:])
        channel = UpdateChannel(rawValue: defaults.string(forKey: "desktop.updateChannel") ?? "stable") ?? .stable
        automaticChecks = defaults.object(forKey: "desktop.automaticChecks") as? Bool ?? true
        super.init()
        // No Sparkle scheduler/installer is started for unprovisioned development builds.
        #if canImport(Sparkle)
        // Paired installation is owned by the native helper; never start a GUI-only installer.
        #endif
        if schedule {
            timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkIfDue() } }
        }
    }
    var label: String {
        switch state {
        case .notChecked: return "Not checked"
        case .checking: return "Checking for updates"
        case .current: return "Up to date"
        case .available: return "Update available"
        case .offline: return "Offline — status unknown"
        case .error: return "Update error"
        case .unavailable: return "No published compatible release"
        }
    }
    var color: Color { state == .current ? .green : state == .available ? .orange : state == .error ? .red : .secondary }
    func loadInstalledHistory(_ backups: URL) {
        let directories = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        installedHistory = directories.filter { $0.lastPathComponent.hasPrefix("ApplicationUpdate-") }.prefix(100).compactMap { folder in
            let url = folder.appendingPathComponent("update-journal.json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 65536,
                  let data = try? Data(contentsOf: url), let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = record["version"] as? String, let phase = record["phase"] as? String else { return nil }
            return InstalledUpdateRecord(id: folder.lastPathComponent, version: version, phase: phase, date: record["date"] as? String ?? "")
        }.sorted { $0.date > $1.date }
    }
    func checkIfDue() {
        guard automaticChecks, state != .checking else { return }
        let date = defaults.object(forKey: "desktop.lastUpdateAttempt") as? Date ?? .distantPast
        if Date().timeIntervalSince(date) >= 86400 { check() }
    }
    func cancel() {
        generation += 1; checkTask?.cancel(); checkTask = nil
        state = .notChecked; detail = "The update check was cancelled. Your installed application is unchanged."
    }
    func check() {
        guard state != .checking else { return }
        generation += 1; let requestGeneration = generation; let selected = channel
        defaults.set(Date(), forKey: "desktop.lastUpdateAttempt")
        state = .checking; detail = "Checking explicitly published desktop releases…"
        checkTask = Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/TTokomon/SumidokuApp/releases?per_page=50")!)
                request.timeoutInterval = 25
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Sumidoku-Desktop/\(installed)", forHTTPHeaderField: "User-Agent")
                if let tag = defaults.string(forKey: "desktop.releaseETag") { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
                let (data,http) = try await fetcher.fetch(request)
                guard generation == requestGeneration, !Task.isCancelled else { return }
                if http.statusCode == 403 || http.statusCode == 429 { state = .offline; detail = "The release service is temporarily unavailable or rate-limited. Retry later."; return }
                guard http.statusCode == 200 || http.statusCode == 304 else { throw UpdateFailure("Release check failed (HTTP \(http.statusCode)). Retry the check.") }
                let bytes = http.statusCode == 304 ? defaults.data(forKey: "desktop.releaseCache") ?? Data() : data
                guard bytes.count <= 2 * 1024 * 1024 else { throw UpdateFailure("Release information exceeded its size limit.") }
                let releases = try JSONDecoder().decode([DesktopRelease].self, from: bytes)
                let result = try ReleaseSelection.evaluate(releases, installed: installed, channel: selected, developmentBuild: developmentBuild)
                if http.statusCode == 200 {
                    defaults.set(bytes, forKey: "desktop.releaseCache")
                    defaults.set(http.value(forHTTPHeaderField: "ETag"), forKey: "desktop.releaseETag")
                }
                lastChecked = Date(); defaults.set(lastChecked, forKey: "desktop.lastUpdateCheck")
                latest = result.latest; history = result.history; state = result.state
                detail = result.state == .current ? "A successful release check confirms this version is current on the selected channel." : result.state == .available ? "A newer desktop release is published. Authenticity and app/server compatibility must be verified before installation." : "No published compatible release confirms this development build's update status. It will keep working normally."
            } catch is CancellationError { }
            catch {
                guard generation == requestGeneration else { return }
                if let error = error as? URLError { state = .offline; detail = error.code == .cancelled ? "Check cancelled." : "The release service could not be reached. Your installed version is unchanged." }
                else { state = .error; detail = error.localizedDescription }
            }
        }
    }
    func waitForCheck() async { await checkTask?.value }
    func refreshInstallation() async {
        await installer?.refresh()
        installationReady = installer?.ready ?? false
        stableRestoreVersion = installer?.stableVersion
        pendingRecovery = installer?.pendingRecovery != nil
    }
    func install(restore: Bool = false, recover: Bool = false) {
        guard (recover ? (installationReady && pendingRecovery && !installing) : canInstall), !restore || canRestoreStable, let installer else { detail = policy.blocker; return }
        installing = true
        detail = restore ? "Verifying the retained Stable app/server pair…" : "Authenticating and preparing the app/server update…"
        Task {
            defer { installing = false }
            do { try await installer.begin(restore:restore,expectedTag:latest?.tag_name,recover:recover) }
            catch { detail = error.localizedDescription; await installer.handoffFailed() }
        }
    }

}

final class ReleaseRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "api.github.com" ? request : nil)
    }
}
#if canImport(Sparkle)
extension AppUpdates: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { channel == .prerelease ? ["beta"] : [] }
}
#endif

struct UpdateStatusButton: View {
    @ObservedObject var updates: AppUpdates
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Circle().fill(updates.color).frame(width: 7, height: 7); Text(updates.label).font(.callout) }
        }.accessibilityLabel("Application updates: \(updates.label)").help("Open application Updates")
    }
}

struct ApplicationUpdatesView: View {
    @ObservedObject var updates: AppUpdates
    @State private var confirmingUpdate = false
    @State private var confirmingRestore = false
    @State private var confirmingRecovery = false
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "arrow.down.app").font(.system(size: 32)).foregroundStyle(DesktopBrand.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Application Updates").font(.title2.bold())
                        Label { Text(updates.label) } icon: { Circle().fill(updates.color).frame(width: 8, height: 8) }
                        Text(updates.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 8)
                LabeledContent("Installed version", value: updates.installed + (updates.developmentBuild ? " · Development" : ""))
                LabeledContent("Latest compatible release", value: updates.latest?.tag_name ?? "Not confirmed")
                if let date = updates.lastChecked { LabeledContent("Last checked") { Text(date, style: .relative) } }
                HStack {
                    Button("Check Now") { updates.check() }.disabled(updates.state == .checking || updates.installing)
                    if updates.state == .checking { ProgressView().controlSize(.small); Button("Cancel Check") { updates.cancel() } }
                    if updates.state == .available { Button("Update Now") { confirmingUpdate = true }.disabled(!updates.canInstall) }
                }
            }
            Section("Preferences") {
                Picker("Release channel", selection: $updates.channel) { Text("Stable").tag(UpdateChannel.stable); Text("Beta (includes Stable)").tag(UpdateChannel.prerelease) }.disabled(updates.installing)
                Toggle("Automatically check for application updates", isOn: $updates.automaticChecks)
                Toggle("Automatically download and install", isOn: $updates.automaticInstallation).disabled(true)
                Text("Application updates are separate from source-package updates. Checks run at most daily. Installation always requires confirmation.").font(.footnote).foregroundStyle(.secondary)
            }
            if !updates.canInstall { Section("Installation availability") { Text(updates.policy.blocker).fixedSize(horizontal: false, vertical: true) } }
            if updates.pendingRecovery {
                Section("Interrupted Update") {
                    Text("A paired update did not complete. Recover the previous verified app/server pair before starting another update. Current data is never rewound.")
                    Button("Recover Interrupted Update…") { confirmingRecovery = true }.disabled(!updates.installationReady || updates.installing)
                }
            }
            Section("Restore Stable") {
                Text("Return to the verified previous Stable app and matching server while keeping the current library and progress. Changing channels alone does not downgrade the app.")
                Button("Restore Stable…") { confirmingRestore = true }.disabled(!updates.canRestoreStable)
                if let version = updates.stableRestoreVersion { Text("Retained Stable: " + version) }
                else { Text("No verified Stable recovery pair is available.").foregroundStyle(.secondary) }
            }
            Section("Installed update history") {
                if updates.installedHistory.isEmpty { Text("No application updates have been recorded by this updater.").foregroundStyle(.secondary) }
                ForEach(updates.installedHistory) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Version " + item.version).fontWeight(.medium)
                        Text(item.phase == "verified" ? "Verified app and server update" : "Update incomplete — recovery retained").font(.caption)
                        Text(item.date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Release history and notes") {
                if updates.history.isEmpty { Text("No published compatible desktop release has been found on this channel.").foregroundStyle(.secondary) }
                ForEach(updates.history.prefix(12)) { release in
                    DisclosureGroup(release.name ?? release.tag_name) {
                        Text(verbatim: release.body ?? "No release notes provided.").textSelection(.enabled).font(.callout)
                    }
                }
            }
        }.tint(DesktopBrand.accent).formStyle(.grouped).padding(12).frame(minWidth: 530, minHeight: 600)
        .confirmationDialog("Install the verified application update?", isPresented:$confirmingUpdate) {
            Button("Back Up, Update and Relaunch") { updates.install() }
        } message: { Text("The app and its owned localhost server will restart together. A cold recovery snapshot is retained; your data is not replaced.") }
        .confirmationDialog("Recover the interrupted update?", isPresented:$confirmingRecovery) {
            Button("Verify and Recover Previous Pair") { updates.install(recover:true) }
        } message: { Text("Recovery stops if current data differs from the journal. The cold snapshot is retained for manual review; no database is restored.") }
        .confirmationDialog("Restore the verified previous Stable version?", isPresented:$confirmingRestore) {
            Button("Back Up and Restore Stable") { updates.install(restore:true) }
        } message: { Text("Your current library and progress stay in place. Restore is refused if the Stable server cannot read the current schema. No database is rewound.") }
    }
}
