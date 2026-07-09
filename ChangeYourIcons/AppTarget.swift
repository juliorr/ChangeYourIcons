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
    @Published var status: String = "Choose an app and find an icon on macosicons.com."
    @Published var isError: Bool = false
    @Published var permissionHint: PermissionHint = .none

    @Published var dockApps: [AppTarget] = []
    @Published var installedApps: [AppTarget] = []
    @Published var source: AppSource = .dock
    @Published var query: String = ""

    let applier = IconApplier()

    func loadLibraries() {
        dockApps = AppLibrary.dockApps()
        installedApps = AppLibrary.installedApps()
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
