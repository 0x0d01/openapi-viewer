import AppKit
import SwiftUI
import WebKit

struct ViewerWebView: NSViewRepresentable {
    let text: String
    let format: String
    let loadID: String
    let filter: String
    let appearance: String
    let onReady: () -> Void
    let onRendered: (Int) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "viewer")

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.update(from: self)
        context.coordinator.loadViewer()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "viewer")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        private var indexURL: URL?
        private var ready = false
        private var currentLoadID = ""
        private var currentText = ""
        private var currentFormat = "yaml"
        private var currentFilter = ""
        private var currentAppearance = "light"
        private var onReady: () -> Void = {}
        private var onRendered: (Int) -> Void = { _ in }
        private var onError: (String) -> Void = { _ in }

        func update(from view: ViewerWebView) {
            onReady = view.onReady
            onRendered = view.onRendered
            onError = view.onError

            let documentChanged =
                currentLoadID != view.loadID || currentText != view.text || currentFormat != view.format
            let filterChanged = currentFilter != view.filter
            let appearanceChanged = currentAppearance != view.appearance
            currentLoadID = view.loadID
            currentText = view.text
            currentFormat = view.format
            currentFilter = view.filter
            currentAppearance = view.appearance

            if ready, documentChanged {
                loadDocument()
            } else if ready, filterChanged {
                callViewer(method: "setFilter", arguments: ["query": currentFilter])
            }
            if ready, appearanceChanged {
                callViewer(method: "setAppearance", arguments: ["appearance": currentAppearance])
            }
        }

        func loadViewer() {
            guard let resourceURL = Bundle.main.resourceURL else {
                onError("The bundled viewer resources are missing.")
                return
            }

            let viewerDirectory = resourceURL.appendingPathComponent("Viewer/dist", isDirectory: true)
            let index = viewerDirectory.appendingPathComponent("index.html")
            guard FileManager.default.fileExists(atPath: index.path) else {
                onError("The bundled viewer could not be found. Build the Viewer assets and rebuild the app.")
                return
            }

            indexURL = index.standardizedFileURL
            let ruleList =
                "[{\"trigger\":{\"url-filter\":\"^https?://\",\"resource-type\":[\"document\",\"image\",\"style-sheet\",\"script\",\"font\",\"raw\",\"svg-document\",\"media\",\"popup\",\"ping\"]},\"action\":{\"type\":\"block\"}}]"
            guard let store = WKContentRuleListStore.default() else {
                onError("Could not enable offline content protection.")
                return
            }
            store.compileContentRuleList(
                forIdentifier: "OpenAPIViewerNetworkBlocker",
                encodedContentRuleList: ruleList
            ) { [weak self] list, error in
                DispatchQueue.main.async {
                    guard let self, let webView = self.webView else { return }
                    guard let list else {
                        self.onError(
                            "Could not enable offline content protection: \(error?.localizedDescription ?? "unknown WebKit error")"
                        )
                        return
                    }
                    webView.configuration.userContentController.add(list)
                    webView.loadFileURL(index, allowingReadAccessTo: viewerDirectory)
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "viewer", message.frameInfo.isMainFrame,
                message.frameInfo.securityOrigin.protocol == "file",
                message.frameInfo.request.url?.standardizedFileURL == indexURL,
                let body = message.body as? [String: Any],
                let type = body["type"] as? String
            else { return }

            switch type {
            case "ready":
                guard !ready else { return }
                ready = true
                onReady()
                loadDocument()
            case "rendered":
                guard body["loadID"] as? String == currentLoadID,
                    let operationCount = body["operationCount"] as? Int
                else { return }
                onRendered(operationCount)
            case "diagnostics":
                guard body["loadID"] as? String == currentLoadID,
                    let diagnostics = body["diagnostics"] as? [[String: Any]]
                else { return }
                let descriptions = diagnostics.compactMap { diagnostic -> String? in
                    guard let message = diagnostic["message"] as? String else { return nil }
                    let severity = diagnostic["severity"] as? String
                    let line = diagnostic["line"] as? Int
                    let column = diagnostic["column"] as? Int
                    let location: String
                    if let line, let column {
                        location = "Line \(line), column \(column): "
                    } else if let line {
                        location = "Line \(line): "
                    } else {
                        location = ""
                    }
                    let prefix = severity.map { "\($0.capitalized): " } ?? ""
                    return prefix + location + message
                }
                if !descriptions.isEmpty {
                    onError(descriptions.joined(separator: "\n"))
                }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if url.scheme == "http" || url.scheme == "https" {
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            if url.standardizedFileURL == indexURL
                || (url.scheme == "file" && url.deletingFragment().standardizedFileURL == indexURL)
            {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError("The specification could not be rendered: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onError("The bundled viewer could not be loaded: \(error.localizedDescription)")
        }

        private func loadDocument() {
            guard ready else { return }
            let arguments: [String: Any] = [
                "loadID": currentLoadID, "text": currentText, "format": currentFormat,
            ]
            callViewer(method: "loadDocument", arguments: arguments)
            callViewer(method: "setFilter", arguments: ["query": currentFilter])
            callViewer(method: "setAppearance", arguments: ["appearance": currentAppearance])
        }

        private func callViewer(method: String, arguments: [String: Any]) {
            guard let webView else { return }
            let source =
                "if (window.viewerBridge && window.viewerBridge.\(method)) { window.viewerBridge.\(method)(payload) }"
            let operationLoadID = currentLoadID
            webView.callAsyncJavaScript(
                source,
                arguments: ["payload": arguments],
                in: nil,
                in: .page,
                completionHandler: { [weak self] result in
                    if case let .failure(error) = result, self?.currentLoadID == operationLoadID {
                        self?.onError(
                            "The viewer could not process the document: \(error.localizedDescription)")
                    }
                }
            )
        }
    }
}

private extension URL {
    func deletingFragment() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.fragment = nil
        return components.url ?? self
    }
}
