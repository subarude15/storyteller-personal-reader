import Foundation

/// The interface between the common core reader stack and a platform's JS
/// engine. Implementations normalize their engine's result shape to a
/// JSON-literal string (WKWebView returns bridged objects, Chromium returns
/// double-encoded JSON; both adapters produce the same String here).
@SilveranUIActor
public protocol JSEvaluating: AnyObject {
    @discardableResult
    func evaluate(_ script: String) async throws -> String?

    /// Runs `source` at document start of every later page load, so state can
    /// be in place before the page's own scripts run. Replaces any earlier
    /// script registered under `key`. Engines without this hook ignore it.
    func setDocumentStartScript(_ source: String, key: String)
}

public extension JSEvaluating {
    func setDocumentStartScript(_ source: String, key: String) {}
}
