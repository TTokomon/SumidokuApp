import AppKit
import WebKit
import ScreenCaptureKit

/// Diagnostic capture of this application's own view tree only. It cannot capture
/// other applications or the desktop and needs no screen-recording permission.
@MainActor
enum OwnWindowCapture {
    static func save(_ window: NSWindow, webView: WKWebView?, to destination: URL) async throws {
        if #available(macOS 14.4, *) {
            // The documented current-process API returns only consent-free content.
            // Match both the actual NSWindow id and our pid; never enumerate/capture
            // another application's content or request desktop-recording permission.
            do {
            let shared = try await SCShareableContent.currentProcess
            guard let own = shared.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw UpdateFailure("This application's window is not available for self-capture.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: own)
            let image: CGImage
            if #available(macOS 26.0, *) {
                let configuration = SCScreenshotConfiguration()
                configuration.showsCursor = false
                configuration.ignoreShadows = true
                configuration.includeChildWindows = false
                configuration.dynamicRange = .sdr
                let result = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
                guard let screenshot = result.sdrImage else { throw UpdateFailure("The own-window screenshot did not contain an SDR image.") }
                image = screenshot
            } else {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(own.frame.width)
                configuration.height = Int(own.frame.height)
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.ignoreShadowsSingleWindow = true
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw UpdateFailure("Window capture encoding failed.") }
            try dataWrite(png, to: destination)
            return
            } catch {
                // Apple's command-line capture can handle WindowServer sessions where
                // ScreenCaptureKit's current-process stream is temporarily unavailable.
                // Restrict it to the same NSWindow id; never capture a screen or region.
                let command = Process()
                command.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                command.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
                command.standardOutput = FileHandle.nullDevice
                command.standardError = FileHandle.nullDevice
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try command.run()
                command.waitUntilExit()
                guard command.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else { throw error }
                return
            }
        }
        guard let view = window.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw UpdateFailure("The application window could not be captured.") }
        view.layoutSubtreeIfNeeded(); window.display()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        if let webView, webView.window === window, !webView.isHidden, webView.alphaValue > 0 {
            let rect = view.convert(webView.bounds, from: webView)
            if rect.width > 0, rect.height > 0 {
                let snapshot = try await webView.takeSnapshot(configuration: nil)
                let output = view.isFlipped ? NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
                image.lockFocus(); snapshot.draw(in: output); image.unlockFocus()
            }
        }
        guard let data = image.tiffRepresentation, let result = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { throw UpdateFailure("The application capture could not be encoded.") }
        try dataWrite(result, to: destination)
    }
    private static func dataWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
