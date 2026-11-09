import AppKit
import Observation
import os

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
    /// Narrower rules for the same correction that this one makes unnecessary.
    var replaces: [VocabularyEntry.ID] = []
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
    private let logger = Logger(subsystem: "com.erikondra.Ara", category: "vocabulary")

    /// Below this confidence the engine was unsure of a word, so a correction
    /// of it is most likely a mishearing and is proposed right away.
    static let uncertainConfidence: Float = 0.8
    /// A correction of a word the engine was sure of could just be rewording.
    /// It is only proposed once it has been made a second time within this many days.
    static let repeatWindowDays = 60

    /// Corrections of confidently heard words that were made once so far.
    private var sightings: [Sighting] = []
    private let sightingsURL: URL

    private struct Sighting: Codable {
        var heard: String
        var replacement: String
        var date: Date
    }

    init(fileURL: URL = .applicationSupportDirectory.appending(path: "Ara/vocabulary.json")) {
        self.fileURL = fileURL
        sightingsURL = fileURL.deletingLastPathComponent().appending(path: "corrections-seen.json")
        if let data = try? Data(contentsOf: sightingsURL),
            let stored = try? JSONDecoder().decode([Sighting].self, from: data)
        {
            let cutoff = Date.now.addingTimeInterval(-Double(Self.repeatWindowDays) * 86_400)
            sightings = stored.filter { $0.date > cutoff }
        }
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
    ///
    /// A correction is only proposed when it is likely a mishearing: the engine
    /// was unsure of the word (`confidences`), the correction was made before,
    /// or it undoes an automatic replacement. Otherwise it is remembered, and
    /// proposed when the same correction is made a second time.
    func proposals(
        inserted: String, edited: String, confidences: [String: Float] = [:], known: inout [CorrectionDiff.Correction]
    ) -> [VocabularyProposal] {
        let corrections = CorrectionDiff.corrections(from: inserted, to: edited).filter { !known.contains($0) }
        known += corrections
        return corrections.compactMap { correction in
            guard let proposal = proposal(for: correction) else { return nil }
            if case .remove = proposal.kind { return proposal }

            let confidence = CorrectionDiff.words(in: correction.heard)
                .compactMap { confidences[$0.lowercased()] }
                .min()
            let isUncertain = confidence.map { $0 < Self.uncertainConfidence } ?? false
            let isRepeat = takeSighting(of: correction)
            // Only numbers go to the log, never the words, to calibrate the threshold.
            let confidenceText = confidence.map { String(format: "%.2f", $0) } ?? "-"
            logger.notice("correction: confidence \(confidenceText, privacy: .public), uncertain \(isUncertain, privacy: .public), repeat \(isRepeat, privacy: .public)")
            if isUncertain || isRepeat { return proposal }

            remember(correction)
            return nil
        }
    }

    // MARK: - Sightings

    private static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether the same correction was made before; if so, it is used up.
    private func takeSighting(of correction: CorrectionDiff.Correction) -> Bool {
        let heard = Self.key(correction.heard)
        let replacement = Self.key(correction.replacement)
        guard let index = sightings.firstIndex(where: { $0.heard == heard && $0.replacement == replacement }) else {
            return false
        }
        sightings.remove(at: index)
        saveSightings()
        return true
    }

    private func remember(_ correction: CorrectionDiff.Correction) {
        sightings.append(Sighting(heard: Self.key(correction.heard), replacement: Self.key(correction.replacement), date: .now))
        // Keeps the file small; the oldest sightings go first.
        sightings = Array(sightings.suffix(300))
        saveSightings()
    }

    private func saveSightings() {
        do {
            try FileManager.default.createDirectory(at: sightingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sightings).write(to: sightingsURL, options: .atomic)
        } catch {
            logger.error("saving the correction sightings failed: \(error, privacy: .public)")
        }
    }

    /// The proposal for a correction that was picked out by hand, not found by watching.
    func proposals(for correction: CorrectionDiff.Correction) -> [VocabularyProposal] {
        proposal(for: correction).map { [$0] } ?? []
    }

    func accept(_ proposal: VocabularyProposal) {
        switch proposal.kind {
        case .add:
            // A new spelling for the same phrase replaces the old rule.
            var updated = entries.filter {
                $0.heard.caseInsensitiveCompare(proposal.heard) != .orderedSame && !proposal.replaces.contains($0.id)
            }
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

        var rule = candidates[0]
        var replaces: [VocabularyEntry.ID] = []
        // The same word was already corrected the same way next to another word,
        // so it is wrong regardless of its neighbours: one general rule replaces the narrow ones.
        if rule.heard != correction.heard {
            let narrower = entries.filter { isNarrower($0, than: correction) }
            if !narrower.isEmpty {
                rule = (correction.heard, correction.replacement)
                replaces = narrower.map(\.id)
            }
        }

        // A rule the user switched off is known already; do not ask about it again.
        let isKnown = entries.contains {
            $0.replacement == rule.replacement && $0.heard.caseInsensitiveCompare(rule.heard) == .orderedSame
        }
        return isKnown
            ? nil
            : VocabularyProposal(kind: .add, heard: rule.heard, replacement: rule.replacement, replaces: replaces)
    }

    /// Whether `entry` is `correction` tied to some neighbouring word,
    /// such as "von Cloud" → "von Claude" for "Cloud" → "Claude".
    private func isNarrower(_ entry: VocabularyEntry, than correction: CorrectionDiff.Correction) -> Bool {
        guard entry.isActive, entry.heard.caseInsensitiveCompare(correction.heard) != .orderedSame,
            let regex = Self.regex(for: correction.heard)
        else { return false }
        let rewritten = regex.stringByReplacingMatches(
            in: entry.heard,
            range: NSRange(entry.heard.startIndex..., in: entry.heard),
            withTemplate: NSRegularExpression.escapedTemplate(for: correction.replacement)
        )
        return rewritten != entry.heard && rewritten.caseInsensitiveCompare(entry.replacement) == .orderedSame
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
        sightings.removeAll()
        saveSightings()
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
