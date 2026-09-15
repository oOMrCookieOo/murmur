import AppKit

/// A copy of the pasteboard's contents, used to put the user's clipboard back
/// the way we found it after borrowing it to paste.
///
/// Captures every representation of every item, not just the plain string, so
/// restoring preserves rich text, images and custom app formats.
struct PasteboardSnapshot: Sendable {

    /// One entry per pasteboard item. Each is an *ordered* list of
    /// (UTI, data) pairs.
    ///
    /// Ordered, not a dictionary: `NSPasteboardItem.types` is sorted by
    /// richness and receivers genuinely consult that order. Restoring through
    /// an unordered `Dictionary` could re-register plain text ahead of RTF, so
    /// a later paste would come out unstyled.
    private let items: [[(type: String, data: Data)]]

    /// How many items the pasteboard actually held when we looked.
    ///
    /// Compared against `items.count` to tell "the clipboard was empty" apart
    /// from "the clipboard had something we could not read" — a distinction
    /// that decides whether restoring is safe.
    private let originalItemCount: Int

    /// True when every item present was captured in full.
    var isComplete: Bool { items.count == originalItemCount }

    static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        let present = pasteboard.pasteboardItems ?? []
        var captured: [[(type: String, data: Data)]] = []

        for item in present {
            var representations: [(type: String, data: Data)] = []
            for type in item.types {
                // Lazy representations (file promises from Mail, Photos, Figma;
                // some drag flavours) return nil here, and an item whose owner
                // has quit returns nil for everything.
                if let data = item.data(forType: type) {
                    representations.append((type.rawValue, data))
                }
            }
            if !representations.isEmpty { captured.append(representations) }
        }

        if captured.count != present.count {
            Log.output.info(
                "Captured \(captured.count, privacy: .public) of \(present.count, privacy: .public) clipboard items"
            )
        }

        return PasteboardSnapshot(items: captured, originalItemCount: present.count)
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

        // Every check happens BEFORE clearContents(), because clearing is the
        // destructive step and there is no undo.
        //
        // An empty `items` does not mean the clipboard was empty: it also
        // happens when capture failed outright (file promises, a quit owner).
        // Clearing in that case would permanently destroy real user data, so
        // when we hold nothing useful we touch nothing at all.
        guard !items.isEmpty else {
            if originalItemCount > 0 {
                // We hold nothing useful and the user had something, so the
                // only safe move is to touch nothing.
                Log.output.warning("Clipboard could not be captured; leaving current contents in place")
                return false
            }
            // Genuinely empty before we borrowed it. Clearing restores that
            // exactly, and stops the transcript lingering on the pasteboard.
            pasteboard.clearContents()
            return true
        }

        if !isComplete {
            Log.output.warning("Restoring a partially captured clipboard")
        }

        pasteboard.clearContents()

        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }

        guard pasteboard.writeObjects(restored) else {
            Log.output.error("Failed to restore the clipboard")
            return false
        }
        return true
    }
}
