import AppKit
import Foundation

/// Finds installed applications so their names can be fed to the recogniser.
///
/// Speech models are trained on ordinary language, so product names like
/// Ghostty, OrbStack or TablePlus come out mangled every time. Supplying them
/// as contextual strings makes the transcriber expect to hear them.
enum AppIndex {

    private static let searchPaths = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Display names of every application in the usual locations, de-duplicated.
    static func installedNames() -> [String] {
        var seen = Set<String>()
        var names: [String] = []

        for path in searchPaths {
            let directory = URL(fileURLWithPath: path)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }

            for url in entries where url.pathExtension == "app" {
                let name = displayName(for: url)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                names.append(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Prefers the bundle's own display name over the filename, since that is
    /// what people say and what the Dock shows.
    private static func displayName(for url: URL) -> String {
        let info = Bundle(url: url)?.infoDictionary
        let candidates = [
            info?["CFBundleDisplayName"] as? String,
            info?["CFBundleName"] as? String,
            url.deletingPathExtension().lastPathComponent,
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
    }
}
