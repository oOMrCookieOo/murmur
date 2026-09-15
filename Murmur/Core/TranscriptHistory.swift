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
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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

    /// The row that was just copied, so the UI can confirm the click landed.
    /// A button that does something invisible reads as a broken button.
    private(set) var lastCopiedID: UUID?
    /// Set briefly after a deletion, for the same reason.
    private(set) var didJustClear = false

    @ObservationIgnored private var feedbackTask: Task<Void, Never>?

    @ObservationIgnored private let fileURL: URL?

    /// - Parameter directory: overrides where the file lives. Only tests pass
    ///   this: `FileManager`'s Application Support lookup does not honour a
    ///   reassigned `$HOME` on macOS, so a test that tried to redirect it that
    ///   way silently wrote to — and corrupted — the real history file.
    init(limit: Int, directory: URL? = nil) {
        fileURL = Self.makeFileURL(in: directory)
        records = Self.load(from: fileURL)
        // Honour a lowered limit at launch rather than waiting for the next
        // dictation to truncate.
        applyLimit(limit)
    }

    /// Trims to `limit`, deleting everything if it is 0.
    ///
    /// Called when the setting changes, not just on the next `add`: "set 0 to
    /// keep nothing" has to mean the file is gone now, especially since a limit
    /// of 0 also hides the Clear button from the menu.
    func applyLimit(_ limit: Int) {
        guard limit > 0 else {
            if !records.isEmpty || fileExists { clear() }
            return
        }
        guard records.count > limit else { return }
        records.removeLast(records.count - limit)
        persist()
    }

    private var fileExists: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
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

        lastCopiedID = record.id
        didJustClear = false
        scheduleFeedbackReset()
    }

    /// Forgets everything, on disk as well as in memory.
    func clear() {
        let hadAnything = !records.isEmpty || fileExists
        records.removeAll()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        lastCopiedID = nil
        if hadAnything {
            didJustClear = true
            scheduleFeedbackReset()
        }
    }

    /// Clears the transient confirmation after a moment.
    private func scheduleFeedbackReset() {
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled, let self else { return }
            self.lastCopiedID = nil
            self.didJustClear = false
        }
    }

    /// Where the file lives, for the "Reveal in Finder" button.
    var storageURL: URL? { fileURL }

    // MARK: - Storage

    private static func makeFileURL(in override: URL?) -> URL? {
        let directory: URL
        if let override {
            directory = override
        } else {
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { return nil }
            directory = support.appendingPathComponent("Murmur", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            // Applied unconditionally, not as a create attribute: an already
            // existing directory keeps whatever mode it had (typically 0755),
            // so the "readable only by your account" promise would be false
            // for anyone whose folder predates this code.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        } catch {
            Log.app.error("Could not prepare history directory: \(error.localizedDescription)")
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
            // (`.completeFileProtection` is an iOS Data Protection class and
            // does nothing here, so it is not requested.)
            try data.write(to: fileURL, options: [.atomic])
            // Re-applied every write: an atomic write replaces the file and the
            // replacement gets default permissions rather than inheriting 0600.
            // There is a brief window at 0644, contained by the 0700 directory.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            Log.app.error("Could not save history: \(error.localizedDescription)")
        }
    }
}
