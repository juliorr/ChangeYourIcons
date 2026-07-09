import AppKit

enum IconError: LocalizedError {
    case cannotLoadImage(URL)
    case invalidImage(URL)
    case appManagementDenied(String)
    case setIconFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage(let url):
            return "Couldn't read the icon image: \(url.lastPathComponent)"
        case .invalidImage(let url):
            return "The file “\(url.lastPathComponent)” isn't a valid image (incomplete download or unsupported format). Please download it again."
        case .appManagementDenied(let path):
            return "macOS blocked modifying \(path). Grant ChangeYourIcons the “App Management” permission in System Settings → Privacy & Security, then try again."
        case .setIconFailed(let path):
            return "The system refused to write the icon to \(path)."
        }
    }

    var isPermissionIssue: Bool {
        if case .appManagementDenied = self { return true }
        return false
    }
}

struct IconApplier {

    func apply(iconAt iconURL: URL, to appURL: URL) throws {
        guard let image = NSImage(contentsOf: iconURL) else {
            throw IconError.cannotLoadImage(iconURL)
        }
        guard image.isValid, !image.representations.isEmpty else {
            throw IconError.invalidImage(iconURL)
        }
        let ok = NSWorkspace.shared.setIcon(image, forFile: appURL.path, options: [])
        if !ok {
            throw classifyWriteFailure(appURL)
        }
        touch(appURL)
    }

    func restore(_ appURL: URL) throws {
        let ok = NSWorkspace.shared.setIcon(nil, forFile: appURL.path, options: [])
        if !ok {
            throw classifyWriteFailure(appURL)
        }
        touch(appURL)
    }

    /// True si podemos escribir dentro del bundle (App Management concedido / no requerido).
    /// Sondea creando y borrando un fichero oculto de 1 byte dentro del bundle.
    func canWriteToBundle(_ appURL: URL) -> Bool {
        let probe = appURL.appendingPathComponent(".changeyouricons_probe")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data([0])) else {
            return false
        }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    private func classifyWriteFailure(_ appURL: URL) -> IconError {
        canWriteToBundle(appURL) ? .setIconFailed(appURL.path) : .appManagementDenied(appURL.path)
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: url.path)
    }

    func refreshDock() {
        killall("Dock")
    }

    private func killall(_ processName: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = [processName]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
    }
}
