/// Finds the words a user corrected by comparing the inserted text with what
/// the text field contained afterwards.
nonisolated enum CorrectionDiff {
    struct Correction: Equatable, Sendable {
        var heard: String
        var replacement: String
        /// The unchanged neighbouring words, used to turn a correction of a
        /// common word into a phrase rule ("Cloud Code" instead of "Cloud").
        var wordBefore: String?
        var wordAfter: String?
    }

    /// A correction replaces at most this many words with at most this many.
    private static let maxWords = 3
    /// More changed places than this means the text was rewritten, not corrected.
    private static let maxChangedPlaces = 3
    /// Corrected words resemble what was heard; rewordings ("gut" → "super") do not.
    private static let minSimilarity = 0.5

    static func corrections(from original: String, to edited: String) -> [Correction] {
        let old = words(in: original)
        let new = words(in: edited)
        guard !old.isEmpty, !new.isEmpty else { return [] }

        // Longest common subsequence of the suffixes old[i...] and new[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in old.indices.reversed() {
            for j in new.indices.reversed() {
                lcs[i][j] = old[i] == new[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var corrections: [Correction] = []
        var changedPlaces = 0
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                i += 1
                j += 1
                continue
            }

            // Collect one run of words that differ between the two texts.
            let removedStart = i
            let insertedStart = j
            while i < old.count || j < new.count {
                if i < old.count, j < new.count, old[i] == new[j] { break }
                if j == new.count || (i < old.count && lcs[i + 1][j] >= lcs[i][j + 1]) {
                    i += 1
                } else {
                    j += 1
                }
            }
            let removed = old[removedStart..<i]
            let inserted = new[insertedStart..<j]

            // Text that was only added or only deleted is not a correction.
            guard !removed.isEmpty, !inserted.isEmpty else { continue }
            changedPlaces += 1

            let heard = removed.joined(separator: " ")
            let replacement = inserted.joined(separator: " ")
            guard removed.count <= maxWords, inserted.count <= maxWords,
                similarity(heard.lowercased(), replacement.lowercased()) >= minSimilarity,
                isMisheard(heard, as: replacement)
            else { continue }

            corrections.append(
                Correction(
                    heard: heard,
                    replacement: replacement,
                    wordBefore: removedStart > 0 ? old[removedStart - 1] : nil,
                    wordAfter: i < old.count ? old[i] : nil
                )
            )
        }

        return changedPlaces <= maxChangedPlaces ? corrections : []
    }

    /// The correction a selected piece of text stands for, for fields that
    /// cannot be read after the edit: the user selects what they wrote and
    /// the closest-sounding words of `original` are taken as what was heard.
    static func correction(forSelection selection: String, in original: String) -> Correction? {
        let replacement = words(in: selection)
        let old = words(in: original)
        guard !replacement.isEmpty, replacement.count <= maxWords, !old.isEmpty else { return nil }

        let wanted = replacement.joined(separator: " ")
        var best: (start: Int, length: Int, similarity: Double)?
        for length in 1...min(maxWords, old.count) {
            for start in 0...(old.count - length) {
                let heard = old[start..<start + length].joined(separator: " ")
                // A selection that already reads like the original is no correction.
                if heard == wanted { return nil }
                let score = similarity(heard.lowercased(), wanted.lowercased())
                if score >= minSimilarity, score > (best?.similarity ?? 0), isMisheard(heard, as: wanted) {
                    best = (start, length, score)
                }
            }
        }
        guard let best else { return nil }

        let end = best.start + best.length
        return Correction(
            heard: old[best.start..<end].joined(separator: " "),
            replacement: wanted,
            wordBefore: best.start > 0 ? old[best.start - 1] : nil,
            wordAfter: end < old.count ? old[end] : nil
        )
    }

    /// Whether changing `heard` into `replacement` looks like fixing a misheard
    /// word, as opposed to other edits that happen in the same text field.
    static func isMisheard(_ heard: String, as replacement: String) -> Bool {
        let heard = heard.lowercased()
        let replacement = replacement.lowercased()
        // Only the case changed, such as a word moved to the start of a sentence.
        guard heard != replacement else { return false }
        // Text was typed or pasted right after the word (such as "[Image #3]"), or the end was cut off.
        guard !replacement.hasPrefix(heard), !heard.hasPrefix(replacement) else { return false }
        // Placeholders that other apps or the speech model put into the text.
        let markers = ["[image", "<unk>"]
        return !markers.contains { heard.contains($0) || replacement.contains($0) }
    }

    /// Words without the punctuation around them; "Next.js" stays whole.
    static func words(in text: String) -> [String] {
        let edges: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", "(", ")", "[", "]", "„", "“", "”", "‚", "‘", "’", "«", "»", "…", "–", "—"]
        return text.split(whereSeparator: \.isWhitespace).compactMap { token in
            var word = Substring(token)
            while let first = word.first, edges.contains(first) { word.removeFirst() }
            while let last = word.last, edges.contains(last) { word.removeLast() }
            return word.isEmpty ? nil : String(word)
        }
    }

    /// 1 for identical strings, 0 for entirely different ones (normalized Levenshtein distance).
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }

        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
