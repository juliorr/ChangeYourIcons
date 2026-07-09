import SwiftUI
import WebKit

struct MacOSIconsWebView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        context.coordinator.webView = webView
        if let url = URL(string: "https://macosicons.com") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.state = state
        context.coordinator.searchIfNeeded(for: state.target?.name)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var state: AppState
        weak var webView: WKWebView?
        private var destinations: [ObjectIdentifier: URL] = [:]
        private var lastSearchedName: String?

        init(state: AppState) {
            self.state = state
        }

        /// Busca automáticamente el nombre de la app seleccionada en macosicons.com.
        /// La comprobación contra `lastSearchedName` evita recargar en bucle, ya que
        /// `updateNSView` se invoca ante cualquier cambio publicado del `AppState`.
        func searchIfNeeded(for name: String?) {
            guard let name, name != lastSearchedName else { return }
            lastSearchedName = name
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://macosicons.com/?query=\(encoded)") else { return }
            webView?.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
            } else {
                decisionHandler(.allow, preferences)
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                decisionHandler(.download)
            }
        }

        func webView(_ webView: WKWebView,
                     navigationAction: WKNavigationAction,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView,
                     navigationResponse: WKNavigationResponse,
                     didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload,
                      decideDestinationUsing response: URLResponse,
                      suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChangeYourIconsDownloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let base = suggestedFilename.isEmpty ? "icon.icns" : suggestedFilename
            var dest = dir.appendingPathComponent(base)
            var i = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                let ext = (base as NSString).pathExtension
                let stem = (base as NSString).deletingPathExtension
                dest = dir.appendingPathComponent("\(stem)-\(i).\(ext)")
                i += 1
            }
            destinations[ObjectIdentifier(download)] = dest
            completionHandler(dest)
        }

        func download(_ download: WKDownload,
                      didFailWithError error: Error,
                      resumeData: Data?) {
            destinations[ObjectIdentifier(download)] = nil
            Task { @MainActor in
                state.setStatus("Download failed: \(error.localizedDescription)", error: true)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let fileURL = destinations[ObjectIdentifier(download)] else { return }
            destinations[ObjectIdentifier(download)] = nil
            Task { @MainActor in
                state.lastDownloadedIcon = fileURL
                if state.target != nil {
                    state.apply(iconURL: fileURL)
                } else {
                    state.setStatus("Icon downloaded (\(fileURL.lastPathComponent)). " +
                                    "Choose an app and click “Apply”.")
                }
            }
        }
    }
}
