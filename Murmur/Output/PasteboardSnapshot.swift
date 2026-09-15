import AppKit

/// A copy of the pasteboard's contents, used to put the user's clipboard back
/// the way we found it after borrowing it to paste.
///
/// Captures every representation of every item, not just the plain string, so
/// restoring preserves rich text, images and custom app formats.
struct PasteboardSnapshot: Sendable {

    /// One dictionary per pasteboard item: UTI string → raw data.
    private let items: [[String: Data]]

    /// `changeCount` at capture time.
    let changeCount: Int

    static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        var captured: [[String: Data]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in item.types {
                // Lazy representations (file promises, some drag flavours) return
                // nil here. Nothing we can do about those; the common formats all
                // come through.
                if let data = item.data(forType: type) {
                    representations[type.rawValue] = data
                }
            }
            if !representations.isEmpty { captured.append(representations) }
        }

        return PasteboardSnapshot(items: captured, changeCount: pasteboard.changeCount)
    }

    /// Puts the captured contents back.
    ///
    /// - Parameter expectedChangeCount: the `changeCount` from immediately after
    ///   *we* wrote the transcript. If the pasteboard has moved on since, some
    ///   other app (or the user) has copied something newer, and restoring would
    ///   destroy it — so we leave it alone.
    /// - Returns: whether the restore happened.
    @discardableResult
    func restore(to pasteboard: NSPasteboard = .general, onlyIfUnchangedFrom expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            Log.output.info("Clipboard changed under us; leaving the newer contents alone")
            return false
        }

        pasteboard.clearContents()

        guard !items.isEmpty else { return true }  // clipboard was genuinely empty

        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
        return true
    }
}
