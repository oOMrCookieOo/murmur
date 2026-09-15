import AppKit
import Foundation

/// One past dictation, kept so a transcript that went somewhere unexpected can
/// still be recovered.
struct TranscriptRecord: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let text: String
    let date: Date
    /// Where it was sent, for context in the menu.
    let destination: String?

    init(id: UUID = UUID(), text: String, date: Date, destination: String?) {
        self.id = id
        self.text = text
        self.date = date
        self.destination = destination
    }

    /// Single-line preview for the menu.
    var preview: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count <= 60 ? collapsed : String(collapsed.prefix(59)) + "…"
    }
}

/// Recent transcripts, persisted across launches.
///
/// ## On storing this at all
///
/// Everything dictated passes through here, so the file is a running log of
/// things said to the Mac. It is written to the user's own Application Support
/// directory with `0600` permissions — owner read/write only — and never leaves
/// the machine. It is **not encrypted**: anything running as this user can read
/// it, as can anything with disk access.
///
/// That is a deliberate, informed trade for a recovery net that actually
/// survives a restart, which an in-memory list does not. `Clear` deletes the
/// file outright, and setting the limit to 0 disables storage entirely.
@MainActor
@Observable
final class TranscriptHistory {

    private(set) var records: [TranscriptRecord] = []

    @ObservationIgnored private let fileURL: URL?

    init() {
        fileURL = Self.makeFileURL()
        records = Self.load(from: fileURL)
    }

    func add(_ text: String, destination: String?, limit: Int) {
        guard limit > 0 else {
            // Storage disabled: make sure nothing is left behind on disk.
            if !records.isEmpty { clear() }
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        records.insert(TranscriptRecord(text: text, date: .now, destination: destination), at: 0)
        if records.count > limit {
            records.removeLast(records.count - limit)
        }
        persist()
    }

    /// Puts a past transcript back on the clipboard. Not concealed: the user
    /// asked for this one explicitly, so their clipboard manager should see it.
    func copyToClipboard(_ record: TranscriptRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.text, forType: .string)
    }

    /// Forgets everything, on disk as well as in memory.
    func clear() {
        records.removeAll()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Where the file lives, for the "Reveal in Finder" button.
    var storageURL: URL? { fileURL }

    // MARK: - Storage

    private static func makeFileURL() -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let directory = support.appendingPathComponent("Murmur", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                // Owner-only on the directory too, so the filename alone is not
                // readable by other users on the machine.
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Log.app.error("Could not create history directory: \(error.localizedDescription)")
            return nil
        }
        return directory.appendingPathComponent("history.json")
    }

    private static func load(from url: URL?) -> [TranscriptRecord] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([TranscriptRecord].self, from: data)
        } catch {
            // A corrupt or outdated file must never stop the app launching.
            Log.app.warning("Discarding unreadable history: \(error.localizedDescription)")
            return []
        }
    }

    private func persist() {
        guard let fileURL else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(records)
            // Atomic so a crash mid-write cannot leave a truncated file.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            // Re-applied every write: an atomic write replaces the file, and
            // the replacement gets default permissions rather than inheriting.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            Log.app.error("Could not save history: \(error.localizedDescription)")
        }
    }
}
