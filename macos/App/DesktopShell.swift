import Combine
import SwiftUI
import WebKit

struct DesktopDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    static let collection = [
        Self(id: "/library", title: "Library", symbol: "books.vertical"),
        Self(id: "/browse", title: "Sources", symbol: "safari"),
        Self(id: "/history", title: "History", symbol: "clock"),
        Self(id: "/downloads", title: "Downloads", symbol: "arrow.down.circle"),
        Self(id: "/updates", title: "Chapter Updates", symbol: "bell")
    ]
    static let settings = [
        Self(id: "/settings", title: "General", symbol: "slider.horizontal.3"),
        Self(id: "/settings?section=reader", title: "Reader", symbol: "book"),
        Self(id: "/settings?section=library", title: "Library & Categories", symbol: "square.grid.2x2"),
        Self(id: "/settings?section=trackers", title: "Trackers", symbol: "link"),
        Self(id: "/settings?section=downloads", title: "Download Preferences", symbol: "arrow.down.circle"),
        Self(id: "/settings?section=source-lists", title: "Source Lists", symbol: "list.bullet.rectangle"),
        Self(id: "/settings?section=backups", title: "Backups & Imports", symbol: "externaldrive"),
        Self(id: "native:server", title: "Server & Account", symbol: "server.rack"),
        Self(id: "native:updates", title: "Application Updates", symbol: "arrow.down.app"),
        Self(id: "/settings?section=system", title: "System", symbol: "info.circle")
    ]
}

struct DesktopShell: View {
    @ObservedObject var controller: ServerController
    @ObservedObject var updates: AppUpdates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibility: NavigationSplitViewVisibility = .all
    var selection: Binding<String?> { Binding(get: { controller.nativePanel.map { "native:" + $0 } ?? (controller.route.hasPrefix("/browse") ? "/browse" : controller.route.hasPrefix("/manga/") ? "/library" : controller.route.hasPrefix("/library") ? "/library" : controller.route) }, set: { if let value = $0 { select(value) } }) }
    func select(_ route: String) {
        if route.hasPrefix("native:") { controller.nativePanel = String(route.dropFirst(7)) }
        else { controller.navigate(route) }
    }
    private func destinationRow(_ item: DesktopDestination) -> some View {
        Label(item.title, systemImage: item.symbol).tag(item.id).contextMenu {
            Button("Open \(item.title)") { select(item.id) }
        }
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: selection) {
                Section("Collection") { ForEach(DesktopDestination.collection) { item in destinationRow(item) } }
                Section("Settings") { ForEach(DesktopDestination.settings) { item in Label(item.title, systemImage: item.symbol).tag(item.id) } }
            }.safeAreaInset(edge: .top, alignment: .leading) {
                HStack(spacing: 10) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName)!)
                        .resizable().frame(width: 30, height: 30).accessibilityHidden(true)
                    Text("Sumidoku").font(.headline)
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 270)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        UpdateStatusButton(updates: updates) { controller.nativePanel = "updates" }.buttonStyle(.plain).padding(8).modifier(NativeControlSurface())
                        Label(controller.available ? "Local server running" : "Server unavailable", systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(.secondary).accessibilityLabel(controller.available ? "Local server running" : "Local server unavailable")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Sumidoku")
        } detail: {
            ZStack {
                // Keep the document alive while a native settings pane is selected.
                EmbeddedInterface(controller: controller).opacity(controller.nativePanel == nil ? 1 : 0)
                    .allowsHitTesting(controller.nativePanel == nil).accessibilityHidden(controller.nativePanel != nil)
                if controller.nativePanel == "updates" { ApplicationUpdatesView(updates: updates) }
                if controller.nativePanel == "server" { ServerSettings(embedded: true, controller: controller) }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(controller.nativePanel == "updates" ? "Application Updates" : controller.nativePanel == "server" ? "Server & Account" : controller.routeTitle)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { controller.nativePanel = nil; controller.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!controller.canGoBack).help("Back")
                    Button { controller.nativePanel = nil; controller.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!controller.canGoForward).help("Forward")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if controller.nativePanel == nil && controller.route.hasPrefix("/reader/") {
                        NativeControlGroup {
                            HStack(spacing: 8) {
                                SystemGlassAction(action: { controller.readerKey("PageUp") }) { Label("Previous page", systemImage: "chevron.up") }
                                SystemGlassAction(action: { controller.readerKey("PageDown") }) { Label("Next page", systemImage: "chevron.down") }
                            }
                        }
                    } else {
                        Button { controller.navigate("/browse?view=search") } label: { Label("Search", systemImage: "magnifyingglass") }.help("Search sources")
                    }
                    Button { Task { await controller.check(reload: true) } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    if controller.nativePanel == nil && controller.route.hasPrefix("/reader/") { UpdateStatusButton(updates: updates) { controller.nativePanel = "updates" } }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(DesktopBrand.accent)
        .transaction { if reduceMotion { $0.animation = nil } }
        .onChange(of: controller.nativePanel) { panel in
            if panel != nil { visibility = .all }
        }
        .onChange(of: controller.route) { value in
            if controller.nativePanel == nil && value.hasPrefix("/reader/") { visibility = .detailOnly }
            else if visibility == .detailOnly { visibility = .all }
        }
    }
}

struct NativePreferences: View {
    @ObservedObject var controller: ServerController
    @ObservedObject var updates: AppUpdates
    @State private var tab = "general"
    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section("Application") {
                    LabeledContent("Version", value: updates.installed)
                    UpdateStatusButton(updates: updates) { tab = "updates" }
                    Button("Check Now") { updates.check() }.disabled(updates.state == .checking)
                    Text(updates.detail).foregroundStyle(.secondary)
                }
                Section("Appearance") { Text("The native window follows your library's light/dark appearance. System contrast, reduced transparency and reduced motion are respected.") }
            }.formStyle(.grouped).padding().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ServerSettings(controller: controller).tabItem { Label("Server & Account", systemImage: "server.rack") }.tag("server")
            ApplicationUpdatesView(updates: updates).tabItem { Label("Updates", systemImage: "arrow.down.app") }.tag("updates")
        }.tint(DesktopBrand.accent).frame(width: 640, height: 690)
    }
}
