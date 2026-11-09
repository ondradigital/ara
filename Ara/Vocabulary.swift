import AppKit
import Observation

/// One spelling the app writes differently from what the speech engine produced.
struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What the speech engine writes.
    var heard: String
    /// What should be written instead.
    var replacement: String
    var isEnabled = true

    var isActive: Bool {
        isEnabled && !heard.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A change to the vocabulary that a correction suggests. It is applied
/// when the countdown ends, unless the user cancels it first.
struct VocabularyProposal: Identifiable, Equatable {
    /// How long the user has to cancel a proposal.
    static let countdown: Duration = .seconds(5)

    enum Kind: Equatable {
        case add
        /// The user changed this rule's automatic replacement back.
        case remove(VocabularyEntry.ID)
    }

    var id = UUID()
    var kind: Kind
    var heard: String
    var replacement: String
    var deadline = Date.now.addingTimeInterval(Double(Self.countdown.components.seconds))
}

/// The personal vocabulary: replacement rules that are applied to every
/// transcript, proposed from corrections or entered by hand.
@Observable
final class VocabularyStore {
    var entries: [VocabularyEntry] = [] {
        didSet { save() }
    }

    private let fileURL: URL

    init(fileURL: URL = .applicationSupportDirectory.appending(path: "Ara/vocabulary.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode([VocabularyEntry].self, from: data)
        {
            entries = stored
        }
    }

    // MARK: - Applying

    /// Rewrites every active rule's phrase in `text`. Longer phrases go
    /// first so "Cloud Code" wins over a rule for "Cloud".
    func apply(to text: String) -> String {
        var result = text
        for entry in entries.filter(\.isActive).sorted(by: { $0.heard.count > $1.heard.count }) {
            guard let regex = Self.regex(for: entry.heard) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.replacement)
            )
        }
        return result
    }

    // MARK: - Learning

    /// Turns the corrections found in `edited` that are not in `known` yet
    /// into proposals for the user to confirm.
    func proposals(
        inserted: String, edited: String, known: inout [CorrectionDiff.Correction]
    ) -> [VocabularyProposal] {
        let corrections = CorrectionDiff.corrections(from: inserted, to: edited).filter { !known.contains($0) }
        known += corrections
        return corrections.compactMap(proposal(for:))
    }

    /// The proposal for a correction that was picked out by hand, not found by watching.
    func proposals(for correction: CorrectionDiff.Correction) -> [VocabularyProposal] {
        proposal(for: correction).map { [$0] } ?? []
    }

    func accept(_ proposal: VocabularyProposal) {
        switch proposal.kind {
        case .add:
            // A new spelling for the same phrase replaces the old rule.
            var updated = entries.filter { $0.heard.caseInsensitiveCompare(proposal.heard) != .orderedSame }
            updated.append(VocabularyEntry(heard: proposal.heard, replacement: proposal.replacement))
            entries = updated
        case .remove(let id):
            entries.removeAll { $0.id == id }
        }
    }

    private func proposal(for correction: CorrectionDiff.Correction) -> VocabularyProposal? {
        let candidates = phrases(for: correction)

        // The user changed an automatic replacement back to what was heard.
        for candidate in candidates {
            if let entry = entries.first(where: {
                $0.isActive && $0.replacement == candidate.heard
                    && $0.heard.caseInsensitiveCompare(candidate.replacement) == .orderedSame
            }) {
                return VocabularyProposal(kind: .remove(entry.id), heard: entry.heard, replacement: entry.replacement)
            }
        }

        let rule = candidates[0]
        // A rule the user switched off is known already; do not ask about it again.
        let isKnown = entries.contains {
            $0.replacement == rule.replacement && $0.heard.caseInsensitiveCompare(rule.heard) == .orderedSame
        }
        return isKnown ? nil : VocabularyProposal(kind: .add, heard: rule.heard, replacement: rule.replacement)
    }

    /// The rule a correction stands for, preferred form first. A corrected
    /// everyday word is widened by a neighbour, so "Cloud" → "Claude" next
    /// to "Code" becomes "Cloud Code" → "Claude Code" and leaves
    /// "Google Cloud" alone.
    private func phrases(for correction: CorrectionDiff.Correction) -> [(heard: String, replacement: String)] {
        let plain = (heard: correction.heard, replacement: correction.replacement)
        var widened: [(heard: String, replacement: String)] = []
        if let after = correction.wordAfter {
            widened.append(("\(correction.heard) \(after)", "\(correction.replacement) \(after)"))
        }
        if let before = correction.wordBefore {
            widened.append(("\(before) \(correction.heard)", "\(before) \(correction.replacement)"))
        }

        let needsContext = !correction.heard.contains(" ") && isCommonWord(correction.heard)
        return needsContext ? widened + [plain] : [plain] + widened
    }

    /// Whether the spell checker knows the word in German or English.
    private func isCommonWord(_ word: String) -> Bool {
        ["de", "en"].contains { language in
            NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
    }

    // MARK: - Editing

    func addManualEntry() {
        entries.append(VocabularyEntry(heard: "", replacement: ""))
    }

    /// Drops rows that were added by hand but never filled in.
    func removeEmptyEntries() {
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespaces).isEmpty }
        if entries.contains(where: { blank($0.heard) && blank($0.replacement) }) {
            entries.removeAll { blank($0.heard) && blank($0.replacement) }
        }
    }

    func deleteAll() {
        entries.removeAll()
    }

    func delete(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    // MARK: - Helpers

    /// Matches the phrase as whole words, ignoring case and the amount of whitespace between words.
    private static func regex(for phrase: String) -> NSRegularExpression? {
        let words = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Ara: saving the vocabulary failed: \(error)")
        }
    }
}
