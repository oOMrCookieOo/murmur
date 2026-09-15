import Foundation
import FoundationModels
import os

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
/// 1. **Filler stripping** — a deterministic regex pass. Instant and offline.
/// 2. **Apple Intelligence polish** — the on-device foundation model fixes
///    capitalisation and punctuation.
///
/// Layer 2 is guarded aggressively. A language model asked to edit text can
/// always decide to *answer* it instead, and pasting a chatbot reply where the
/// user expected their own words is far worse than pasting scruffy dictation.
/// Every failure mode — unavailable, timeout, error, output truncation, or
/// output that drifts from the input — falls back to the text we started with.
actor TranscriptCleaner {

    /// Reused across dictations so model warm-up does not land inside the
    /// key-up latency budget. Discarded after a timeout, because an abandoned
    /// in-flight request would make the next call fail with `concurrentRequests`.
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

    // MARK: - Prewarming

    /// Builds and warms the model session during idle time.
    func prewarm() async {
        guard case .available = SystemLanguageModel.default.availability else { return }
        guard session == nil else { return }

        let newSession = LanguageModelSession(instructions: Self.instructions)
        newSession.prewarm()
        session = newSession
        Log.cleanup.info("Cleanup session prewarmed")
    }

    // MARK: - Entry point

    func clean(_ raw: String, settings: SettingsData) async -> CleanupResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .keptRaw(raw, reason: nil) }

        // Layer 1: deterministic.
        var deterministic = trimmed
        if settings.stripFillers {
            let stripped = Self.stripFillers(from: trimmed, locale: settings.locale)
            // An utterance that was entirely fillers must not become an empty
            // paste; the user still said something.
            deterministic = stripped.isEmpty ? trimmed : stripped
        }

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

        return await polish(deterministic, timeout: .milliseconds(settings.polishTimeoutMilliseconds))
    }

    // MARK: - Model pass

    private func polish(_ text: String, timeout: Duration) async -> CleanupResult {
        if session == nil { await prewarm() }
        guard let session else { return .keptRaw(text, reason: "Cleanup unavailable") }

        // Generous but finite. Cleanup should never produce much more than it
        // was given; a cap well above that catches runaway generation.
        //
        // Note `usage.output.totalTokenCount` includes reasoning tokens, so a
        // model that reasoned heavily could trip this cap and degrade to
        // keptRaw. That is the safe direction, which is why it is acceptable.
        let tokenCap = max(64, Self.estimatedTokens(text) * 2 + 32)

        let options = GenerationOptions(
            samplingMode: .greedy,          // deterministic: same input, same output
            maximumResponseTokens: tokenCap
        )

        let outcome = await withTimeout(timeout) { () -> CleanupResult in
            do {
                let response = try await session.respond(to: text, options: options)

                // A truncated edit is worse than no edit: it silently drops the
                // end of what the user said.
                if response.usage.output.totalTokenCount >= tokenCap {
                    return .keptRaw(text, reason: "Cleanup hit its output limit")
                }

                let candidate = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isFaithful(original: text, candidate: candidate) else {
                    return .keptRaw(text, reason: "Cleanup changed too much")
                }
                return .cleaned(candidate)
            } catch {
                Log.cleanup.warning("Polish failed: \(error.localizedDescription)")
                return .keptRaw(text, reason: "Cleanup failed")
            }
        }

        guard let outcome else {
            // The abandoned request may still be running inside the session, so
            // the session cannot be reused — a second respond would throw
            // `concurrentRequests`.
            self.session = nil
            Task { await self.prewarm() }
            Log.cleanup.info("Polish timed out")
            return .keptRaw(text, reason: "Cleanup timed out")
        }
        return outcome
    }

    // MARK: - Safety checks

    /// True when `candidate` is plausibly the same text, tidied.
    ///
    /// Three independent gates, because a set-overlap score alone is far too
    /// weak. "what is the capital of france" → "The capital of France is Paris."
    /// scored 0.75 under the old check and was accepted — the model answering
    /// the text is the exact threat this function exists to stop.
    static func isFaithful(original: String, candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }

        // Gate 1: gross length drift.
        let ratio = Double(candidate.count) / Double(max(original.count, 1))
        guard ratio > 0.5, ratio < 2.0 else { return false }

        let originalWords = contentWords(original)
        let candidateWords = contentWords(candidate)

        // Fail closed. An original with no content words ("so is it on") gives
        // the comparison nothing to work with, and accepting anything on no
        // evidence is the wrong default for a guard — that path accepted
        // "It is on fire." as a faithful rendering.
        guard !originalWords.isEmpty else { return false }

        // Gate 2: the original's content words must survive nearly intact AND
        // in their original order. Order matters — it is what catches a
        // reordering like "john at 5 and mary at 7" becoming "john at 7 and
        // mary at 5", which set membership scores as perfect.
        let originalCore = collapsingStutters(originalWords)
        let candidateCore = collapsingStutters(candidateWords)
        let retained = longestCommonSubsequenceLength(originalCore, candidateCore)

        // Proportional AND absolute. A ratio alone gets looser the longer you
        // speak: at 0.95 a 100-word dictation may silently shed its last five
        // words, which is exactly the kind of loss nobody notices until later.
        guard Double(retained) / Double(originalCore.count) >= 0.95,
              retained >= originalCore.count - 1
        else { return false }

        // Nothing may be appended after the user's last word.
        //
        // This is the gate that stops the model answering instead of editing.
        // An answer, a summary, and a "Sure, here you go" all attach at the
        // end, and every one of them survives the budget below: "what is the
        // capital of france" → "What is the capital of France? Paris." keeps
        // every original word in order and inserts just one.
        guard let finalWord = originalCore.last,
              let tail = candidateCore.lastIndex(of: finalWord),
              tail == candidateCore.count - 1
        else { return false }

        // Gate 3: cap what the model may ADD. Without this a candidate can keep
        // every original word and still append an answer, a summary, or
        // "Sure! Here is the corrected version:".
        var budget: [String: Int] = [:]
        for word in originalCore { budget[word, default: 0] += 1 }

        var inserted = 0
        for word in candidateCore {
            if let remaining = budget[word], remaining > 0 {
                budget[word] = remaining - 1
            } else {
                inserted += 1
            }
        }
        return Double(inserted) <= 0.2 * Double(originalCore.count) + 2
    }

    /// Length of the longest common subsequence of the two word lists.
    ///
    /// A greedy prefix walk is not good enough: it cannot recover once it fails
    /// to match, so a single legitimately-removed word cascades into scoring
    /// almost everything as lost. "the the parser" → "the parser" is a
    /// transformation we explicitly ask the model for, and greedy matching
    /// rejected it outright.
    ///
    /// O(n·m), on two word lists from a single utterance — a few thousand
    /// operations at worst.
    private static func longestCommonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        // Only two rows are ever needed, so the table stays O(m).
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous

        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Collapses immediately repeated words ("the the" → "the").
    ///
    /// Applied to both sides before comparison because removing stutters is
    /// something rule 4 of the instructions actively requests, so it must not
    /// be scored as lost content.
    private static func collapsingStutters(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words where result.last != word {
            result.append(word)
        }
        return result
    }

    /// Filler words removed by the deterministic pass.
    ///
    /// Deliberately excludes "mm" (a unit: "5 mm"), "er" and "ah" (ordinary
    /// words in German, French and many names). Those three caused real
    /// corruption: "The bolt is 5 mm wide" became "The bolt is 5 wide".
    private static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm",
    ]

    /// Words ignored when comparing meaning. Kept wider than `fillerWords`
    /// because the *model* may legitimately remove these even when our own
    /// deterministic pass would not.
    private static let ignorableWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mm", "er", "ah",
    ]

    private static func contentWords(_ text: String) -> [String] {
        // Apostrophes are folded away first so a model turning "dont" into
        // "don't" does not read as one word lost and one word invented.
        let folded = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")

        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                guard !word.isEmpty, !ignorableWords.contains(word) else { return false }
                // Short tokens are usually grammatical noise, but short NUMBERS
                // are content — "at 5" vs "at 7" is a meaning change.
                return word.count > 2 || word.contains(where: \.isNumber)
            }
    }

    // MARK: - Deterministic pass

    /// Removes standalone filler words and tidies what they leave behind.
    ///
    /// Only applied to English: the filler list is English-specific, and
    /// applying it to other languages deletes real words.
    static func stripFillers(from text: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "en" else { return text }

        // Three guards around the alternation:
        //   (?<!\\d\\s) — "um" is the ASCII spelling of micrometres, so "5 um wide"
        //                must survive. Same class of bug as "mm".
        //   (?![-'’])   — "um-hum" must not lose its first half and keep the hyphen.
        //   (?:,(?= ))? — a trailing comma goes only when a space follows, so
        //                "um, hello" loses it but a clause separator never does.
        let pattern = "(?<!\\d\\s)\\b(?:"
            + fillerWords.sorted().joined(separator: "|")
            + ")\\b(?![-'\u{2019}])(?:,(?= ))?"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")

        // Collapse the runs of spaces the deletions leave, without touching
        // newlines — multi-line dictation must keep its structure.
        result = result.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
        // "Hmm. Let me think." would otherwise start with an orphan full stop.
        result = result.replacingOccurrences(of: "^[\\s]*[,.!?;:]+[\\s]*", with: "", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Rough token estimate: English averages about four characters per token.
    private static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:           return "This Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
        case .modelNotReady:               return "Apple Intelligence is still downloading"
        @unknown default:                  return "Apple Intelligence unavailable"
        }
    }
}
