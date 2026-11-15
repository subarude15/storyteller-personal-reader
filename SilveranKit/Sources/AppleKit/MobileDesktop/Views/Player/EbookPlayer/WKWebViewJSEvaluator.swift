#if os(iOS) || os(macOS)
import Foundation
import WebKit

@MainActor
final class WKWebViewJSEvaluator: JSEvaluating {
    weak var webView: WKWebView?
    private var documentStartScripts: [String: String] = [:]

    init(webView: WKWebView? = nil) {
        self.webView = webView
    }

    @discardableResult
    func evaluate(_ script: String) async throws -> String? {
        guard let webView else {
            throw ReaderCommsBridgeError.jsNotAvailable
        }
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    // ponytail: WKUserContentController cannot remove one script, so each new
    // value under a key appends a script and the last one added wins. Callers
    // only register a few distinct values per WebView (e.g. the controls mode).
    func setDocumentStartScript(_ source: String, key: String) {
        guard documentStartScripts[key] != source,
            let controller = webView?.configuration.userContentController
        else { return }
        documentStartScripts[key] = source
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }
}
#endif
