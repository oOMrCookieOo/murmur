import Foundation

/// Tests for transcript history: the limit, deletion, and recovery from a
/// corrupt file.
///
/// History is the only thing standing between a dictation that went somewhere
/// unexpected and losing it, and it now writes to disk — so "the limit is
/// honoured" and "clear actually deletes" are claims worth holding to.
///
/// Uses a temporary HOME so the real history file is never touched.
@main
struct HistoryTests {

    static func main() async {
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL")  \(label)")
        }

        // The directory is injected, not redirected via $HOME: FileManager's
        // Application Support lookup ignores $HOME on macOS, so an earlier
        // version of this test wrote to the real history file and corrupted it.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("murmur-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let history = await TranscriptHistory(limit: 20, directory: sandbox)
        guard let url = await history.storageURL else {
            print("FAIL  no storage URL")
            exit(1)
        }
        check("starts empty", await history.records.isEmpty)

        print("\n=== the limit is enforced, newest kept ===")
        for index in 1...25 {
            await history.add("entry \(index)", destination: "Test", limit: 20)
        }
        check("capped at the limit", await history.records.count == 20)
        check("newest is first", await history.records.first?.text == "entry 25")
        check("oldest were dropped", await history.records.last?.text == "entry 6")

        print("\n=== it survives a relaunch ===")
        let reloaded = await TranscriptHistory(limit: 20, directory: sandbox)
        check("reloaded from disk", await reloaded.records.count == 20)
        check("order preserved", await reloaded.records.first?.text == "entry 25")

        print("\n=== lowering the limit trims immediately, at launch ===")
        let trimmed = await TranscriptHistory(limit: 5, directory: sandbox)
        check("trimmed on load", await trimmed.records.count == 5)
        check("kept the newest", await trimmed.records.first?.text == "entry 25")

        print("\n=== a limit of 0 deletes the file ===")
        let disabled = await TranscriptHistory(limit: 0, directory: sandbox)
        check("nothing kept", await disabled.records.isEmpty)
        check("file removed", !FileManager.default.fileExists(atPath: url.path))

        print("\n=== clear() removes memory and disk ===")
        let fresh = await TranscriptHistory(limit: 20, directory: sandbox)
        await fresh.add("something", destination: nil, limit: 20)
        check("wrote a record", await fresh.records.count == 1)
        check("file created", FileManager.default.fileExists(atPath: url.path))
        await fresh.clear()
        check("records gone", await fresh.records.isEmpty)
        check("file gone", !FileManager.default.fileExists(atPath: url.path))

        print("\n=== the file is owner-only ===")
        await fresh.add("permissions", destination: nil, limit: 20)
        if let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber {
            check("file is 0600", mode.intValue == 0o600)
        } else {
            check("file is 0600", false)
        }
        if let dir = try? FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber {
            check("directory is 0700", dir.intValue == 0o700)
        } else {
            check("directory is 0700", false)
        }

        print("\n=== a corrupt file must not stop launch ===")
        try? "this is not json".write(to: url, atomically: true, encoding: .utf8)
        let recovered = await TranscriptHistory(limit: 20, directory: sandbox)
        check("recovered as empty", await recovered.records.isEmpty)

        print("\n=== empty text is ignored ===")
        let counted = await recovered.records.count
        await recovered.add("   \n  ", destination: nil, limit: 20)
        check("whitespace not recorded", await recovered.records.count == counted)

        print("\n=== the real history file must be untouched ===")
        let realPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Murmur/history.json").path
        check("tests wrote inside the sandbox", url.path.hasPrefix(sandbox.path))
        check("sandbox is not the real location", url.path != realPath)

        print("")
        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILURE(S)")
            exit(1)
        }
    }
}
