import SwiftUI
import AppKit

enum DesktopBrand {
    // Existing Sumidoku brand red, shared by native navigation and controls.
    static let accent = Color(red: 1, green: 47.0 / 255, blue: 82.0 / 255)
}

struct SurfacePolicy: Equatable {
    enum Material { case liquidGlass, systemMaterial, opaque }
    static func material(majorVersion: Int, reduceTransparency: Bool, increasedContrast: Bool) -> Material {
        if reduceTransparency || increasedContrast { return .opaque }
        return majorVersion >= 26 ? .liquidGlass : .systemMaterial
    }
}
struct NativeControlSurface: ViewModifier {
    var forceSystemMaterial = false
    var reduceTransparencyOverride: Bool?
    var increasedContrastOverride: Bool?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let highContrast = increasedContrastOverride ?? (contrast == .increased)
        let material = SurfacePolicy.material(majorVersion: forceSystemMaterial ? 25 : ProcessInfo.processInfo.operatingSystemVersion.majorVersion, reduceTransparency: reduceTransparencyOverride ?? reduceTransparency, increasedContrast: highContrast)
        if material == .opaque {
            content.background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(highContrast ? 0.6 : 0.25)))
        } else if #available(macOS 26.0, *), material == .liquidGlass {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
    }
}
struct NativeControlGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 12) { content() } }
        else { content() }
    }
}
struct SystemGlassAction<Label: View>: View {
    var forceBordered = false
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased, !forceBordered { Button(action: action, label: label).buttonStyle(.glass) }
        else { Button(action: action, label: label).buttonStyle(.bordered) }
    }
}

/// Symbol names are resolved on the running OS, including older supported Macs.
enum NativeSymbol {
    static func resolve(_ preferred: String, available: (String) -> Bool = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }) -> String {
        if available(preferred) { return preferred }
        let fallback = preferred == "clock.arrow.2.circlepath" ? "clock.arrow.circlepath" : "circle"
        return available(fallback) ? fallback : "questionmark.circle"
    }
}
