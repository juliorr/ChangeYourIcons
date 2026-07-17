import AppKit

/// Un icono guardado de forma permanente en disco, listo para reutilizarse.
struct SavedIcon: Identifiable, Equatable {
    let url: URL
    var id: URL { url }

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Miniatura para la galería. `NSImage` lee `.icns`/`.png`/etc. igual que en
    /// `AppTarget.currentIcon` y `IconApplier.apply`.
    var thumbnail: NSImage? {
        NSImage(contentsOf: url)
    }
}

/// Almacena los iconos descargados en Application Support para poder reutilizarlos.
/// Sin red: solo `FileManager`.
struct IconLibrary {
    /// Extensiones que consideramos iconos válidos.
    private static let imageExtensions: Set<String> = ["icns", "png", "jpg", "jpeg", "tiff"]

    /// `~/Library/Application Support/ChangeYourIcons/Icons`, creada si no existe.
    var iconsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base
            .appendingPathComponent("ChangeYourIcons", isDirectory: true)
            .appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Destino único dentro de `iconsDirectory`, evitando colisiones con sufijos `-1`, `-2`, …
    func destinationURL(for suggestedFilename: String) -> URL {
        let dir = iconsDirectory
        let base = suggestedFilename.isEmpty ? "icon.icns" : suggestedFilename
        var dest = dir.appendingPathComponent(base)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let ext = (base as NSString).pathExtension
            let stem = (base as NSString).deletingPathExtension
            dest = dir.appendingPathComponent("\(stem)-\(i).\(ext)")
            i += 1
        }
        return dest
    }

    /// Todos los iconos guardados, más recientes primero.
    func all() -> [SavedIcon] {
        let dir = iconsDirectory
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        return urls
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let ld = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rd = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return ld > rd
            }
            .map(SavedIcon.init)
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
