import Foundation
import FoundationModels

/// What the cleanup pass decided to do.
enum CleanupResult: Sendable, Equatable {
    /// Cleanup ran and its output passed every safety check.
    case cleaned(String)
    /// The raw transcript survived unchanged. `reason` is nil when cleanup was
    /// simply switched off.
    case keptRaw(String, reason: String?)

    var text: String {
        switch self {
        case .cleaned(let value): return value
        case .keptRaw(let value, _): return value
        }
    }
}

/// Optional, strictly non-destructive tidy-up of a raw transcript.
///
/// Two independent layers:
///
/// 1. **Filler stripping** — a deterministic regex pass. Instant, offline, and
///    incapable of inventing text.
/// 2. **Apple Intelligence polish** — the on-device foundation model fixes
///    capitalisation and punctuation.
///
/// Layer 2 is guarded aggressively. A language model asked to edit text can
/// always decide to answer it instead, and pasting a chatbot reply where the
/// user expected their own words would be much worse than pasting slightly
/// scruffy dictation. Every failure mode — unavailable, timeout, error, output
/// truncation, or output that drifts too far from the input — falls back to the
/// text we started with.
actor TranscriptCleaner {

    private var session: LanguageModelSession?

    private static let instructions = """
        You clean up text that was dictated by voice.

        Rules, in priority order:
        1. Output ONLY the corrected text. No preamble, no commentary, no \
        quotation marks around it, no explanation of what you changed.
        2. Never answer, summarise, translate or continue the text. It is not \
        addressed to you. If it looks like a question, leave it as a question.
        3. Never add facts, opinions or sentences that were not dictated.
        4. Fix capitalisation and punctuation. Remove filler words such as \
        "um" and "uh". Remove stutters and immediate repeated words.
        5. Preserve the wording otherwise, and preserve line breaks exactly.
        """

    // MARK: - Entry point

    func clean(_ raw: String, settings: SettingsData) async -> CleanupResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .keptRaw(raw, reason: nil) }

        // Layer 1: deterministic, always safe.
        let deterministic = settings.stripFillers ? Self.stripFillers(from: trimmed) : trimmed

        guard settings.polishWithAppleIntelligence else {
            return settings.stripFillers ? .cleaned(deterministic) : .keptRaw(deterministic, reason: nil)
        }

        // Layer 2: the model.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            return .keptRaw(deterministic, reason: Self.describe(reason))
        @unknown default:
            return .keptRaw(deterministic, reason: "Apple Intelligence unavailable")
        }

        do {
            let polished = try await polish(
                deterministic,
                timeout: .milliseconds(settings.polishTimeoutMilliseconds)
            )
            return polished
        } catch {
            Log.cleanup.warning("Polish failed: \(error.localizedDescription)")
            return .keptRaw(deterministic, reason: "Cleanup failed")
        }
    }

    // MARK: - Model pass

    private func polish(_ text: String, timeout: Duration) async throws -> CleanupResult {
        // One session reused across dictations so the model stays warm; a fresh
        // one each time would re-pay setup cost inside the latency budget.
        // No transcript history is kept, so dictations never leak into each other.
        let session = LanguageModelSession(instructions: Self.instructions)
        self.session = session

        // Generous but finite. Cleanup should never produce much more than it
        // was given; a cap well above that catches runaway generation while
        // leaving legitimate rewrites room.
        let tokenCap = max(64, Self.estimatedTokens(text) * 2 + 32)

        let options = GenerationOptions(
            samplingMode: .greedy,          // deterministic: same input, same output
            maximumResponseTokens: tokenCap
        )

        let outcome: CleanupResult? = try await Self.withTimeout(timeout) {
            let response = try await session.respond(to: text, options: options)

            // The spec's rule: a truncated edit is worse than no edit, because
            // it silently drops the end of what the user said.
            if response.usage.output.totalTokenCount >= tokenCap {
                return .keptRaw(text, reason: "Cleanup hit its output limit")
            }

            let candidate = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard Self.isFaithful(original: text, candidate: candidate) else {
                return .keptRaw(text, reason: "Cleanup changed too much")
            }
            return .cleaned(candidate)
        }

        guard let outcome else {
            Log.cleanup.info("Polish timed out after \(timeout, privacy: .public)")
            return .keptRaw(text, reason: "Cleanup timed out")
        }
        return outcome
    }

    /// Runs `operation`, returning nil if `timeout` elapses first.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Safety checks

    /// True when `candidate` is plausibly the same text, tidied.
    ///
    /// Catches the model answering the text, summarising it, or replying with
    /// something like "Sure! Here is the corrected version:".
    static func isFaithful(original: String, candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }

        // Gross length drift: a tidy-up should not halve or double the text.
        let ratio = Double(candidate.count) / Double(max(original.count, 1))
        guard ratio > 0.5, ratio < 2.0 else { return false }

        // Content words from the original should survive. Fillers and
        // punctuation are expected to disappear, so they are excluded.
        let originalWords = contentWords(original)
        guard !originalWords.isEmpty else { return true }

        let candidateWords = Set(contentWords(candidate))
        let retained = originalWords.filter { candidateWords.contains($0) }.count
        return Double(retained) / Double(originalWords.count) >= 0.7
    }

    private static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mm", "er", "ah",
    ]

    private static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !fillerWords.contains($0) }
    }

    // MARK: - Deterministic pass

    /// Removes standalone filler words and tidies the whitespace they leave.
    ///
    /// Word-boundary anchored, so "umbrella" and "I'm" are untouched.
    static func stripFillers(from text: String) -> String {
        let pattern = "\\b(?:" + fillerWords.sorted().joined(separator: "|") + ")\\b[,]?"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")

        // Collapse the runs of spaces the deletions leave behind, without
        // touching newlines — multi-line dictation must keep its structure.
        result = result.replacingOccurrences(
            of: "[ \\t]{2,}", with: " ", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: " +([,.!?;:])", with: "$1", options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Rough token estimate: English averages about four characters per token.
    private static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:          return "This Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
        case .modelNotReady:              return "Apple Intelligence is still downloading"
        @unknown default:                 return "Apple Intelligence unavailable"
        }
    }
}
