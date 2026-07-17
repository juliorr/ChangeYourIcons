import SwiftUI
import WebKit

/// Fuente web de iconos que se muestra en el panel derecho. Centraliza las URLs
/// de cada sitio para que el resto del código no tenga hosts hardcodeados.
enum IconWebSource: String, CaseIterable, Identifiable {
    case macosIcons = "macOS Icons"
    case flaticon   = "Flaticon"
    case icons8     = "Icons8"
    case iconIcons  = "Icon-Icons"

    var id: String { rawValue }

    var homeURL: URL {
        switch self {
        case .macosIcons: return URL(string: "https://macosicons.com")!
        case .flaticon:   return URL(string: "https://www.flaticon.com")!
        case .icons8:     return URL(string: "https://icons8.com/icons/")!
        case .iconIcons:  return URL(string: "https://icon-icons.com")!
        }
    }

    /// URL de búsqueda del nombre de la app en la fuente. `nil` si el nombre no
    /// puede percent-encodearse.
    func searchURL(query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        switch self {
        case .macosIcons: return URL(string: "https://macosicons.com/?query=\(encoded)")
        case .flaticon:   return URL(string: "https://www.flaticon.com/search?word=\(encoded)")
        case .icons8:     return URL(string: "https://icons8.com/icons/set/\(encoded)")
        case .iconIcons:  return URL(string: "https://icon-icons.com/search?q=\(encoded)")
        }
    }
}

struct MacOSIconsWebView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    /// JS inyectado en el WebView para recuperar miniaturas que fallan al cargar.
    /// macosicons.com es una SPA (Nuxt) y su CDN de imágenes devuelve 504 de forma
    /// intermitente; reintentar la misma URL con cache-bust suele resolverlas.
    /// Diseñado para ser suave con el servidor: backoff, tope de intentos por imagen
    /// y límite de reintentos concurrentes.
    static let retryImagesJS = """
    (function () {
      if (window.__cyiRetryInstalled) return;
      window.__cyiRetryInstalled = true;

      var MAX_ATTEMPTS = 3;     // reintentos por imagen
      var MAX_INFLIGHT = 4;     // reintentos concurrentes máximos
      var BASE_DELAY = 800;     // ms, crece exponencialmente
      var PENDING_MS = 12000;   // una img sin resolver más de esto se considera colgada
      var inflight = 0;

      function isBroken(img) { return img.complete && img.naturalWidth === 0; }

      function stamp(img) {
        if (!img.dataset.cyiSeen) {
          img.dataset.cyiSeen = '1';
          img.dataset.cyiFirst = String(Date.now());
        }
      }

      function stalled(img) {
        var t = parseInt(img.dataset.cyiFirst || '0', 10);
        return !img.complete && t && (Date.now() - t) > PENDING_MS;
      }

      function retry(img) {
        var attempts = parseInt(img.dataset.cyiAttempts || '0', 10);
        if (attempts >= MAX_ATTEMPTS) return;
        if (inflight >= MAX_INFLIGHT) return;
        if (img.dataset.cyiBusy === '1') return;

        img.dataset.cyiBusy = '1';
        img.dataset.cyiAttempts = String(attempts + 1);
        inflight++;

        var delay = BASE_DELAY * Math.pow(2, attempts) + Math.floor(Math.random() * 400);
        setTimeout(function () {
          try {
            var base = (img.currentSrc || img.src || '').split('#')[0];
            if (!base) { done(img); return; }
            var sep = base.indexOf('?') === -1 ? '?' : '&';
            // quitar cache-bust previo para no acumular parámetros
            base = base.replace(/([?&])_cyi=\\d+/, '').replace(/[?&]$/, '');
            sep = base.indexOf('?') === -1 ? '?' : '&';
            img.src = base + sep + '_cyi=' + (attempts + 1);
          } catch (e) { /* noop */ }
          // liberar el slot poco después, haya cargado o no
          setTimeout(function () { done(img); }, 200);
        }, delay);
      }

      function done(img) {
        if (img.dataset.cyiBusy === '1') { img.dataset.cyiBusy = '0'; inflight = Math.max(0, inflight - 1); }
      }

      function consider(img) {
        stamp(img);
        if (img.naturalWidth > 0) return;      // ya cargó bien
        if (isBroken(img) || stalled(img)) retry(img);
      }

      function attach(img) {
        stamp(img);
        if (img.dataset.cyiHooked === '1') return;
        img.dataset.cyiHooked = '1';
        img.addEventListener('error', function () { retry(img); });
        img.addEventListener('load', function () {
          if (img.naturalWidth > 0) { img.dataset.cyiAttempts = '0'; done(img); }
        });
      }

      function sweep() {
        var imgs = document.images;
        for (var i = 0; i < imgs.length; i++) { attach(imgs[i]); consider(imgs[i]); }
      }

      // Enganchar imágenes que la SPA inserta al buscar
      var mo = new MutationObserver(function () { sweep(); });
      mo.observe(document.documentElement, { childList: true, subtree: true });

      // Barrido periódico para rotas / colgadas
      setInterval(sweep, 4000);
      sweep();
    })();
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Reintenta automáticamente las miniaturas que fallan: el servidor de
        // imágenes de macosicons.com devuelve 504 de forma intermitente.
        let retryScript = WKUserScript(source: Self.retryImagesJS,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true)
        config.userContentController.addUserScript(retryScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        context.coordinator.webView = webView
        context.coordinator.lastSource = state.webSource
        webView.load(URLRequest(url: state.webSource.homeURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.state = state
        context.coordinator.reloadIfSourceChanged(to: state.webSource, targetName: state.target?.name)
        context.coordinator.searchIfNeeded(for: state.target?.name)
        context.coordinator.reloadIfNeeded(counter: state.webReloadCounter)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var state: AppState
        weak var webView: WKWebView?
        private var destinations: [ObjectIdentifier: URL] = [:]
        private var lastSearchedName: String?
        private var lastReloadCounter = 0
        var lastSource: IconWebSource = .macosIcons

        init(state: AppState) {
            self.state = state
        }

        /// Busca automáticamente el nombre de la app seleccionada en la fuente activa.
        /// La comprobación contra `lastSearchedName` evita recargar en bucle, ya que
        /// `updateNSView` se invoca ante cualquier cambio publicado del `AppState`.
        func searchIfNeeded(for name: String?) {
            guard let name, name != lastSearchedName else { return }
            lastSearchedName = name
            guard let url = state.webSource.searchURL(query: name) else { return }
            webView?.load(URLRequest(url: url))
        }

        /// Recarga la web cuando el usuario cambia de fuente (macOS Icons ↔ Flaticon).
        /// Resetea `lastSearchedName` para que la nueva fuente rebusque el nombre de la
        /// app actual (vía `searchIfNeeded`), o cargue su home si no hay app seleccionada.
        func reloadIfSourceChanged(to source: IconWebSource, targetName: String?) {
            guard source != lastSource else { return }
            lastSource = source
            lastSearchedName = nil
            if targetName == nil {
                webView?.load(URLRequest(url: source.homeURL))
            }
            // Si hay app seleccionada, `searchIfNeeded` (llamado justo después en
            // updateNSView) cargará la búsqueda en la nueva fuente.
        }

        /// Recarga la página actual cuando el usuario pulsa el botón de recargar.
        /// El contador evita recargar en bucle (updateNSView se llama en cada cambio del estado).
        func reloadIfNeeded(counter: Int) {
            guard counter != lastReloadCounter else { return }
            lastReloadCounter = counter
            webView?.reload()
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
            // Flaticon sirve los iconos como PNG/SVG con `Content-Disposition: attachment`.
            // Un PNG es mostrable inline (canShowMIMEType == true), así que sin esto el
            // web view lo abriría en vez de descargarlo. Forzamos descarga cuando el
            // servidor marca la respuesta como adjunto.
            if let http = navigationResponse.response as? HTTPURLResponse,
               let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
               disposition.lowercased().contains("attachment") {
                decisionHandler(.download)
                return
            }
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
            // Se descarga directo a la carpeta permanente (Application Support) para
            // que el icono quede guardado y reutilizable, no en un temporal volátil.
            let dest = state.iconLibrary.destinationURL(for: suggestedFilename)
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
                // SVG no se puede aplicar como icono: NSImage no lo rasteriza para
                // NSWorkspace.setIcon. Avisamos y pedimos la versión PNG en vez de
                // aplicarlo o marcarlo como último icono descargado.
                if fileURL.pathExtension.lowercased() == "svg" {
                    state.setStatus("Downloaded an SVG — SVG can't be applied as an app icon. " +
                                    "Download the PNG version instead.", error: true)
                    return
                }
                state.lastDownloadedIcon = fileURL
                state.reloadSavedIcons()
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
