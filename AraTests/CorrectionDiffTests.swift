import Testing

/// `CorrectionDiff.swift` is compiled into this bundle directly, so no import of the app is needed.
struct CorrectionDiffTests {
    @Test func findsASingleCorrectedWord() {
        let corrections = CorrectionDiff.corrections(from: "Ich nutze Cloud Code jeden Tag", to: "Ich nutze Claude Code jeden Tag")
        #expect(corrections == [
            .init(heard: "Cloud", replacement: "Claude", wordBefore: "nutze", wordAfter: "Code"),
        ])
    }

    @Test func ignoresPunctuationAroundWords() {
        let corrections = CorrectionDiff.corrections(from: "Das ist Next.js.", to: "Das ist Next.js!")
        #expect(corrections.isEmpty)
    }

    @Test func ignoresRewordings() {
        // "gut" and "super" do not look alike, so this is no misheard word.
        #expect(CorrectionDiff.corrections(from: "Das ist gut", to: "Das ist super").isEmpty)
    }

    @Test func ignoresAddedOrDeletedText() {
        #expect(CorrectionDiff.corrections(from: "Hallo Welt", to: "Hallo schöne Welt").isEmpty)
        #expect(CorrectionDiff.corrections(from: "Hallo schöne Welt", to: "Hallo Welt").isEmpty)
    }

    @Test func treatsManyChangesAsARewrite() {
        let original = "eins zwei drei vier fünf sechs sieben acht"
        let edited = "einz zwei dreu vier fümf sechs siebem acht"
        #expect(CorrectionDiff.corrections(from: original, to: edited).isEmpty)
    }

    @Test func findsTheCorrectionForASelection() {
        let correction = CorrectionDiff.correction(forSelection: "Claude", in: "Ich nutze Cloud Code jeden Tag")
        #expect(correction?.heard == "Cloud")
        #expect(correction?.wordBefore == "nutze")
        #expect(correction?.wordAfter == "Code")
    }

    @Test func selectionThatMatchesTheOriginalIsNoCorrection() {
        #expect(CorrectionDiff.correction(forSelection: "Code", in: "Ich nutze Cloud Code") == nil)
    }

    @Test func similarity() {
        #expect(CorrectionDiff.similarity("abc", "abc") == 1)
        #expect(CorrectionDiff.similarity("abc", "xyz") == 0)
        #expect(CorrectionDiff.similarity("", "") == 1)
    }
}
