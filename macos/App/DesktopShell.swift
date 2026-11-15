import Combine
import SwiftUI
import WebKit

struct DesktopDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    // Symbols reference Aidoku’s own SF Symbol choices (see docs/AIDOKU_SYMBOLS.md).
    // The glyphs are rendered by macOS, not copied from Aidoku’s GPLv3 assets.
    static let collection = [
        Self(id: "/library", title: "Library", symbol: "books.vertical.fill"),
        Self(id: "/browse", title: "Sources", symbol: "globe"),
        Self(id: "/history", title: "History", symbol: "clock.fill"),
        Self(id: "/downloads", title: "Downloads", symbol: "arrow.down.circle.fill"),
        Self(id: "/updates", title: "Chapter Updates", symbol: "clock.arrow.2.circlepath")
    ]
    // Detailed settings live behind a single entry. Legacy web URLs remain
    // valid and are selected inside the five-category settings page.
    static let settings = [
        Self(id: "/settings", title: "Settings", symbol: "gear")
    ]
    var iconColor: Color {
        switch id {
        case "/library": return DesktopBrand.accent
        case "/browse": return .green
        case "/history": return .orange
        case "/downloads": return .blue
        case "/updates": return .purple
        default: return .secondary
        }
    }
}

struct DesktopShell: View {
    @ObservedObject var controller: ServerController
    @ObservedObject var updates: AppUpdates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibility: NavigationSplitViewVisibility = .all
    var selection: Binding<String?> {
        Binding(
            get: {
                if controller.nativePanel != nil || controller.route.hasPrefix("/settings") { return "/settings" }
                if controller.route.hasPrefix("/browse") { return "/browse" }
                if controller.route.hasPrefix("/manga/") || controller.route.hasPrefix("/library") { return "/library" }
                return controller.route
            },
            set: { if let value = $0 { select(value) } }
        )
    }
    func select(_ route: String) {
        if route.hasPrefix("native:") { controller.nativePanel = String(route.dropFirst(7)) }
        else { controller.navigate(route) }
    }
    private func destinationRow(_ item: DesktopDestination) -> some View {
        Label {
            Text(item.title).font(.system(size: 15, weight: .medium))
        } icon: {
            Image(systemName: NativeSymbol.resolve(item.symbol))
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(item.iconColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
        .tag(item.id)
        .contextMenu { Button("Open \(item.title)") { select(item.id) } }
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: selection) {
                Section("Collection") { ForEach(DesktopDestination.collection) { item in destinationRow(item) } }
                Section("Preferences") { ForEach(DesktopDestination.settings) { item in destinationRow(item) } }
            }.safeAreaInset(edge: .top, alignment: .leading) {
                HStack(spacing: 14) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName)!)
                        .resizable().interpolation(.high)
                        .frame(width: 48, height: 48).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sumidoku").font(.system(size: 21, weight: .bold))
                        Text("Desktop").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 20)
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 235, ideal: 270, max: 320)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { controller.nativePanel = "updates" } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text("App Updates").font(.callout)
                                Spacer(minLength: 4)
                                Circle().fill(updates.color).frame(width: 8, height: 8)
                                Text(updates.label).font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("App Updates: \(updates.label). Open update settings.")
                        Button { controller.nativePanel = "server" } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "server.rack").foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text("Local Server").font(.callout)
                                Spacer(minLength: 4)
                                Circle().fill(controller.available ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(controller.available ? "Running" : "Unavailable")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(controller.available ? "Local server running. Open server controls." : "Local server unavailable. Open server controls.")
                    }
                    .padding(13)
                    .modifier(NativeControlSurface())
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            }.formStyle(.grouped).padding().tabItem { Label("General", systemImage: "gear") }.tag("general")
            ServerSettings(controller: controller).tabItem { Label("Server & Account", systemImage: "gearshape.2.fill") }.tag("server")
            ApplicationUpdatesView(updates: updates).tabItem { Label("Updates", systemImage: NativeSymbol.resolve("clock.arrow.2.circlepath")) }.tag("updates")
        }.tint(DesktopBrand.accent).frame(width: 640, height: 690)
    }
}
