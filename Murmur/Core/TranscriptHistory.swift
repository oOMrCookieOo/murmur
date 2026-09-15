import AppKit
import Foundation

/// One past dictation, kept so a transcript that went somewhere unexpected can
/// still be recovered.
struct TranscriptRecord: Identifiable, Sendable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
    /// Where it was sent, for context in the menu.
    let destination: String?

    /// Single-line preview for the menu.
    var preview: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count <= 60 ? collapsed : String(collapsed.prefix(59)) + "…"
    }
}

/// A bounded, in-memory list of recent transcripts.
///
/// **In memory only, and deliberately so.** Everything a user dictates passes
/// through here — passwords read aloud, messages, medical notes. Writing that
/// to disk would create a plaintext log of everything ever said to the app,
/// which is a far worse default than losing history at quit. The whole premise
/// of Murmur is that speech does not outlive the moment.
@MainActor
@Observable
final class TranscriptHistory {
    private(set) var records: [TranscriptRecord] = []

    func add(_ text: String, destination: String?, limit: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        records.insert(TranscriptRecord(text: text, date: .now, destination: destination), at: 0)
        if records.count > limit {
            records.removeLast(records.count - limit)
        }
    }

    /// Puts a past transcript back on the clipboard. Not concealed: the user
    /// asked for this one explicitly, so their clipboard manager should see it.
    func copyToClipboard(_ record: TranscriptRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.text, forType: .string)
    }

    func clear() {
        records.removeAll()
    }
}
