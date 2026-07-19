import AppKit

struct AppTarget: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    var path: String { url.path }

    var currentIcon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    var isSystemProtected: Bool {
        let p = url.resolvingSymlinksInPath().path
        return p.hasPrefix("/System/")
    }

    static func == (lhs: AppTarget, rhs: AppTarget) -> Bool {
        lhs.url == rhs.url
    }
}

enum PermissionHint {
    case none          // todo OK
    case appManagement // falta permiso "Gestión de apps"
    case sip           // app protegida por SIP, sin solución
}

final class AppState: ObservableObject {
    @Published var target: AppTarget?
    @Published var lastDownloadedIcon: URL?
    @Published var status: String = "Choose an app and find an icon in the panel on the right."
    @Published var isError: Bool = false
    @Published var permissionHint: PermissionHint = .none

    @Published var dockApps: [AppTarget] = []
    @Published var installedApps: [AppTarget] = []
    @Published var source: AppSource = .dock
    @Published var query: String = ""

    /// Fuente web de iconos activa en el panel derecho (macOS Icons / Flaticon).
    @Published var webSource: IconWebSource = .macosIcons

    @Published var savedIcons: [SavedIcon] = []

    /// Se incrementa para pedir al `WKWebView` que recargue la página actual.
    /// Útil porque macosicons.com sirve miniaturas de forma diferida y a veces
    /// devuelve 504 en algunas imágenes; recargar suele resolverlas.
    @Published var webReloadCounter = 0

    let applier = IconApplier()
    let iconLibrary = IconLibrary()
    /// Convierte SVGs a PNG (thesvg.org, subidas .svg) para poder aplicarlos como icono.
    let rasterizer = SVGRasterizer()

    func reloadWeb() {
        webReloadCounter += 1
    }

    func loadLibraries() {
        dockApps = AppLibrary.dockApps()
        installedApps = AppLibrary.installedApps()
        reloadSavedIcons()
    }

    func reloadSavedIcons() {
        savedIcons = iconLibrary.all()
    }

    @MainActor
    func deleteSavedIcon(_ icon: SavedIcon) {
        iconLibrary.delete(icon.url)
        if lastDownloadedIcon == icon.url { lastDownloadedIcon = nil }
        reloadSavedIcons()
    }

    var visibleApps: [AppTarget] {
        let base = (source == .dock) ? dockApps : installedApps
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    @MainActor
    func select(_ app: AppTarget) {
        target = app
        if app.isSystemProtected {
            setStatus("“\(app.name)” is protected by SIP; its icon can't be changed.", error: true)
            permissionHint = .sip
        } else if !applier.canWriteToBundle(app.url) {
            // Detección proactiva: falta el permiso "Gestión de apps" antes de intentar aplicar.
            setStatus("ChangeYourIcons needs the “App Management” permission to modify “\(app.name)”.", error: true)
            permissionHint = .appManagement
        } else if let icon = lastDownloadedIcon {
            setStatus("“\(app.name)” selected. Click “Apply” to use the last downloaded icon (\(icon.lastPathComponent)).")
        } else {
            setStatus("“\(app.name)” selected. Download an icon in the panel on the right.")
        }
    }

    @MainActor
    func setStatus(_ message: String, error: Bool = false) {
        self.status = message
        self.isError = error
        self.permissionHint = .none
    }

    @MainActor
    private func setError(_ error: Error, prefix: String) {
        self.status = "\(prefix): \(error.localizedDescription)"
        self.isError = true
        self.permissionHint = ((error as? IconError)?.isPermissionIssue ?? false) ? .appManagement : .none
    }

    func openAppManagementSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    @MainActor
    func apply(iconURL: URL) {
        guard let target else {
            setStatus("Choose an app (.app) on the left first.", error: true)
            return
        }
        if target.isSystemProtected {
            setStatus("“\(target.name)” is protected by SIP and its icon can't be changed.", error: true)
            permissionHint = .sip
            return
        }
        do {
            try applier.apply(iconAt: iconURL, to: target.url)
            applier.refreshDock()
            objectWillChange.send()
            setStatus("Icon applied to “\(target.name)”. Dock restarted.")
        } catch {
            setError(error, prefix: "Couldn't apply the icon")
        }
    }

    /// Procesa un archivo recién descargado por el WebView. Si es un SVG lo rasteriza a PNG;
    /// en otro caso continúa con el flujo normal (recordar, refrescar galería y aplicar).
    @MainActor
    func importDownloadedFile(_ fileURL: URL) {
        if fileURL.pathExtension.lowercased() == "svg" {
            rasterizeAndApply(svgAt: fileURL, deletingSourceAfter: true)
        } else {
            finishImportedIcon(fileURL)
        }
    }

    /// Importa un icono elegido del disco por el usuario. Un `.svg` se rasteriza a PNG; el
    /// resto de formatos (png/jpg/tiff/icns) se copian a la librería y se aplican.
    @MainActor
    func importLocalIcon(from sourceURL: URL) {
        if sourceURL.pathExtension.lowercased() == "svg" {
            rasterizeAndApply(svgAt: sourceURL, deletingSourceAfter: false)
            return
        }
        let dest = iconLibrary.destinationURL(for: sourceURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            finishImportedIcon(dest)
        } catch {
            setStatus("Couldn't import the icon: \(error.localizedDescription)", error: true)
        }
    }

    /// Rasteriza un SVG a PNG en la librería y sigue con el flujo normal. `deleteSource`
    /// borra el `.svg` de origen tras convertirlo (útil para descargas, que ya cayeron en la
    /// librería; no para subidas, cuyo origen está fuera y no queremos tocar).
    @MainActor
    private func rasterizeAndApply(svgAt svgURL: URL, deletingSourceAfter deleteSource: Bool) {
        let stem = svgURL.deletingPathExtension().lastPathComponent
        let dest = iconLibrary.destinationURL(for: "\(stem.isEmpty ? "icon" : stem).png")
        setStatus("Converting SVG to a usable icon…")
        rasterizer.rasterize(svgAt: svgURL, to: dest) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if deleteSource { try? FileManager.default.removeItem(at: svgURL) }
                switch result {
                case .success(let pngURL):
                    self.finishImportedIcon(pngURL)
                case .failure(let error):
                    self.setStatus("Couldn't convert the SVG: \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    /// Cola común tras obtener un icono aplicable: recordarlo, refrescar la galería y
    /// aplicarlo si hay una app seleccionada.
    @MainActor
    private func finishImportedIcon(_ fileURL: URL) {
        lastDownloadedIcon = fileURL
        reloadSavedIcons()
        if target != nil {
            apply(iconURL: fileURL)
        } else {
            setStatus("Icon ready (\(fileURL.lastPathComponent)). " +
                      "Choose an app and click “Apply”.")
        }
    }

    @MainActor
    func restore() {
        guard let target else {
            setStatus("Choose an app (.app) first.", error: true)
            return
        }
        do {
            try applier.restore(target.url)
            applier.refreshDock()
            objectWillChange.send()
            setStatus("Original icon restored on “\(target.name)”.")
        } catch {
            setError(error, prefix: "Couldn't restore the icon")
        }
    }
}
