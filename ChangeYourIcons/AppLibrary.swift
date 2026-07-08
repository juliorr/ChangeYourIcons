import AppKit

enum AppSource: String, CaseIterable, Identifiable {
    case dock = "Dock"
    case installed = "All"
    var id: String { rawValue }
}

enum AppLibrary {

    static func dockApps() -> [AppTarget] {
        guard let defaults = UserDefaults(suiteName: "com.apple.dock"),
              let persistent = defaults.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return []
        }
        let fm = FileManager.default
        var seen = Set<String>()
        var results: [AppTarget] = []
        for entry in persistent {
            guard let tile = entry["tile-data"] as? [String: Any],
                  let fileData = tile["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String,
                  let url = URL(string: urlString) else { continue }
            let fileURL = (url.isFileURL ? url : URL(fileURLWithPath: urlString)).standardizedFileURL
            guard fileURL.pathExtension == "app",
                  fm.fileExists(atPath: fileURL.path),
                  seen.insert(fileURL.path).inserted else { continue }
            results.append(AppTarget(url: fileURL))
        }
        return results
    }

    static func installedApps() -> [AppTarget] {
        let fm = FileManager.default
        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
        ].map { URL(fileURLWithPath: $0) }

        var seen = Set<String>()
        var results: [AppTarget] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for item in items where item.pathExtension == "app" {
                let path = item.standardizedFileURL.path
                if seen.insert(path).inserted {
                    results.append(AppTarget(url: item.standardizedFileURL))
                }
            }
        }
        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
