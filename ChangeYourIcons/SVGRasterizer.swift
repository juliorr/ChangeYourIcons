import AppKit
import WebKit

/// Rasteriza un SVG a PNG usando un `WKWebView` fuera de pantalla.
///
/// `NSImage`/`NSWorkspace.setIcon` no saben renderizar vectores, así que los iconos SVG
/// (p.ej. los de thesvg.org, o los que el usuario sube desde el disco) no se pueden aplicar
/// tal cual. Aquí cargamos el SVG en un WebView oculto, lo dejamos que se dibuje centrado y
/// a escala dentro de un cuadrado, y capturamos un snapshot que guardamos como PNG cuadrado
/// (1024 px) con fondo transparente, listo para `IconApplier`.
///
/// WebKit ya es dependencia del proyecto, así que no añade nada externo.
final class SVGRasterizer: NSObject, WKNavigationDelegate {
    /// Lado del PNG resultante, en píxeles.
    private let pixelSize: CGFloat = 1024

    /// Lado del lienzo del WebView, en puntos. El SVG se ajusta (contain) dentro de él.
    private let canvasSize: CGFloat = 512

    enum RasterizeError: LocalizedError {
        case unreadableSVG(URL)
        case snapshotFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableSVG(let url):
                return "Couldn't read the SVG file: \(url.lastPathComponent)"
            case .snapshotFailed:
                return "Couldn't render the SVG to an image."
            case .encodingFailed:
                return "Couldn't encode the rendered icon as PNG."
            }
        }
    }

    /// Trabajo de rasterización en curso. Mantiene vivos el WebView y su ventana oculta
    /// (si el WebView no está en una ventana, el snapshot puede salir en blanco).
    private final class Job {
        let window: NSWindow
        let webView: WKWebView
        let destination: URL
        let completion: (Result<URL, Error>) -> Void

        init(window: NSWindow, webView: WKWebView, destination: URL,
             completion: @escaping (Result<URL, Error>) -> Void) {
            self.window = window
            self.webView = webView
            self.destination = destination
            self.completion = completion
        }
    }

    private var jobs: [ObjectIdentifier: Job] = [:]

    /// Rasteriza el SVG en `svgURL` y escribe un PNG en `destination`.
    /// `completion` se invoca en el hilo principal (los callbacks de WebKit lo son).
    /// Debe llamarse desde el hilo principal.
    func rasterize(svgAt svgURL: URL, to destination: URL,
                   completion: @escaping (Result<URL, Error>) -> Void) {
        guard let svg = try? String(contentsOf: svgURL, encoding: .utf8) else {
            completion(.failure(RasterizeError.unreadableSVG(svgURL)))
            return
        }

        let frame = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        // Fondo transparente en el snapshot (KVC; API privada, aceptable en app ad-hoc/personal).
        webView.setValue(false, forKey: "drawsBackground")

        // Ventana oculta lejos de la pantalla visible para forzar el layout/paint sin parpadeo.
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = webView
        window.orderBack(nil)

        // Envuelve el SVG en un lienzo cuadrado; `max-width/height:100%` lo ajusta (contain)
        // conservando proporción, así los logos no cuadrados quedan centrados con relleno
        // transparente en vez de deformados.
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; }
          #box {
            width: \(Int(canvasSize))px; height: \(Int(canvasSize))px;
            display: flex; align-items: center; justify-content: center;
            box-sizing: border-box;
          }
          #box svg, #box img {
            max-width: 100%; max-height: 100%;
            width: auto; height: auto; display: block;
          }
        </style>
        </head>
        <body><div id="box">\(svg)</div></body>
        </html>
        """

        jobs[ObjectIdentifier(webView)] = Job(window: window, webView: webView,
                                              destination: destination, completion: completion)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let job = jobs[ObjectIdentifier(webView)] else { return }
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(origin: .zero, size: webView.bounds.size)
        webView.takeSnapshot(with: config) { [weak self] image, error in
            self?.handleSnapshot(job: job, webView: webView, image: image, error: error)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(webView: webView, result: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(webView: webView, result: .failure(error))
    }

    // MARK: - Snapshot → PNG

    private func handleSnapshot(job: Job, webView: WKWebView, image: NSImage?, error: Error?) {
        if let error {
            finish(webView: webView, result: .failure(error))
            return
        }
        guard let image else {
            finish(webView: webView, result: .failure(RasterizeError.snapshotFailed))
            return
        }
        guard let png = pngData(from: image) else {
            finish(webView: webView, result: .failure(RasterizeError.encodingFailed))
            return
        }
        do {
            try png.write(to: job.destination)
            finish(webView: webView, result: .success(job.destination))
        } catch {
            finish(webView: webView, result: .failure(error))
        }
    }

    private func finish(webView: WKWebView, result: Result<URL, Error>) {
        let key = ObjectIdentifier(webView)
        guard let job = jobs[key] else { return }
        jobs[key] = nil
        job.window.contentView = nil
        job.window.close()
        job.completion(result)
    }

    /// Normaliza `image` (el snapshot cuadrado del WebView) a un PNG cuadrado de
    /// `pixelSize`×`pixelSize` px con fondo transparente.
    private func pngData(from image: NSImage) -> Data? {
        let pixels = Int(pixelSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx

        let square = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        // El snapshot ya viene ajustado y centrado en un cuadrado, así que escalarlo al
        // cuadrado destino conserva la proporción del icono.
        image.draw(in: square, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.flushGraphics()

        return rep.representation(using: .png, properties: [:])
    }
}
