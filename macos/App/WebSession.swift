import Foundation
import WebKit

// Tear down the document (including its SSE stream) before graceful shutdown.
// stopLoading alone does not close an already-running EventSource.
@MainActor
final class WebSessionQuiescer: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Void, Error>?
    static func suspend(_ view: WKWebView) async throws {
        guard view.url != nil else { return }
        let delegate = WebSessionQuiescer()
        let previous = view.navigationDelegate
        defer { view.navigationDelegate = previous }
        try await withCheckedThrowingContinuation { continuation in
            delegate.pending = continuation
            view.stopLoading()
            view.navigationDelegate = delegate
            view.loadHTMLString("", baseURL: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                delegate.finish(LibraryFailure(text: "The interface could not be paused. Close its window and try again; the server was not stopped."))
            }
        }
    }
    private func finish(_ error: Error? = nil) {
        guard let continuation = pending else { return }
        pending = nil
        if let error = error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.absoluteString == "about:blank" { finish() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
}
