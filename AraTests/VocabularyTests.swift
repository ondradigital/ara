import Foundation
import Testing

/// `Vocabulary.swift` is compiled into this bundle directly, so no import of the app is needed.
struct VocabularyTests {
    /// A store that writes to a throwaway file instead of the real vocabulary.
    private func makeStore(_ entries: [VocabularyEntry] = [], at url: URL? = nil) -> VocabularyStore {
        let url = url ?? FileManager.default.temporaryDirectory.appending(path: "AraTests-\(UUID().uuidString)/vocabulary.json")
        let store = VocabularyStore(fileURL: url)
        store.entries = entries
        return store
    }

    @Test func replacesWholeWordsIgnoringCase() {
        let store = makeStore([VocabularyEntry(heard: "cloud code", replacement: "Claude Code")])
        #expect(store.apply(to: "Ich nutze Cloud  Code.") == "Ich nutze Claude Code.")
        // Part of a longer word stays untouched.
        #expect(store.apply(to: "Cloud Codes") == "Cloud Codes")
    }

    @Test func longerPhrasesWin() {
        let store = makeStore([
            VocabularyEntry(heard: "Cloud", replacement: "Wolke"),
            VocabularyEntry(heard: "Cloud Code", replacement: "Claude Code"),
        ])
        #expect(store.apply(to: "Cloud Code und Cloud") == "Claude Code und Wolke")
    }

    @Test func skipsDisabledAndEmptyRules() {
        let store = makeStore([
            VocabularyEntry(heard: "Cloud", replacement: "Wolke", isEnabled: false),
            VocabularyEntry(heard: " ", replacement: "x"),
        ])
        #expect(store.apply(to: "Cloud ist da") == "Cloud ist da")
    }

    @Test func replacementIsTakenLiterally() {
        let store = makeStore([VocabularyEntry(heard: "Preis", replacement: "$1 \\0")])
        #expect(store.apply(to: "Der Preis") == "Der $1 \\0")
    }

    @Test func acceptingAProposalReplacesTheOldRule() {
        let store = makeStore([VocabularyEntry(heard: "Cloud Code", replacement: "Clod Code")])
        store.accept(VocabularyProposal(kind: .add, heard: "cloud code", replacement: "Claude Code"))
        #expect(store.entries.map(\.replacement) == ["Claude Code"])
    }

    @Test func undoingAReplacementProposesRemovingIt() {
        let store = makeStore([VocabularyEntry(heard: "Cloud", replacement: "Claude")])
        var known: [CorrectionDiff.Correction] = []
        let proposals = store.proposals(inserted: "Das ist Claude hier", edited: "Das ist Cloud hier", known: &known)
        #expect(proposals.count == 1)
        #expect(proposals.first?.kind == .remove(store.entries[0].id))
    }

    @Test func removesOnlyBlankEntries() {
        let store = makeStore([
            VocabularyEntry(heard: "", replacement: " "),
            VocabularyEntry(heard: "Cloud", replacement: ""),
        ])
        store.removeEmptyEntries()
        #expect(store.entries.map(\.heard) == ["Cloud"])
    }

    @Test func deleteAllEmptiesTheVocabulary() {
        let store = makeStore([VocabularyEntry(heard: "Cloud", replacement: "Claude")])
        store.deleteAll()
        #expect(store.entries.isEmpty)
    }

    @Test func commonWordIsFirstTiedToItsNeighbour() {
        let store = makeStore()
        var known: [CorrectionDiff.Correction] = []
        let proposals = store.proposals(
            inserted: "Ich nutze Cloud Code", edited: "Ich nutze Claude Code", confidences: ["cloud": 0.4], known: &known
        )
        #expect(proposals.map(\.heard) == ["Cloud Code"])
    }

    @Test func secondNeighbourMakesTheRuleGeneral() {
        let store = makeStore([
            VocabularyEntry(heard: "Cloud Code", replacement: "Claude Code"),
            VocabularyEntry(heard: "von Cloud", replacement: "von claude"),
            VocabularyEntry(heard: "Google Cloud", replacement: "Google Cloud"),
        ])
        var known: [CorrectionDiff.Correction] = []
        let proposals = store.proposals(
            inserted: "Das kann Cloud gut", edited: "Das kann Claude gut", confidences: ["cloud": 0.4], known: &known
        )
        #expect(proposals.count == 1)
        #expect(proposals.first?.heard == "Cloud")
        #expect(proposals.first?.replaces.count == 2)

        store.accept(proposals[0])
        #expect(store.entries.map(\.heard).sorted() == ["Cloud", "Google Cloud"])
    }

    @Test func confidentWordIsOnlyProposedTheSecondTime() {
        let url = FileManager.default.temporaryDirectory.appending(path: "AraTests-\(UUID().uuidString)/vocabulary.json")
        let store = makeStore(at: url)
        var known: [CorrectionDiff.Correction] = []
        let first = store.proposals(
            inserted: "Wir wohnen im Juringerweg", edited: "Wir wohnen im Joringelweg",
            confidences: ["juringerweg": 0.95], known: &known
        )
        #expect(first.isEmpty)

        // A later dictation, after the app was restarted.
        let restarted = makeStore(at: url)
        var laterKnown: [CorrectionDiff.Correction] = []
        let second = restarted.proposals(
            inserted: "Der Juringerweg ist gesperrt", edited: "Der Joringelweg ist gesperrt",
            confidences: ["juringerweg": 0.95], known: &laterKnown
        )
        #expect(second.map(\.replacement) == ["Joringelweg"])
    }

    @Test func rewordingOnceIsNotProposed() {
        let store = makeStore()
        var known: [CorrectionDiff.Correction] = []
        let proposals = store.proposals(
            inserted: "Ich würde empfehlen die Datei", edited: "Ich würde entfernen die Datei",
            confidences: ["empfehlen": 0.99], known: &known
        )
        #expect(proposals.isEmpty)
    }

    @Test func uncertainWordIsProposedRightAway() {
        let store = makeStore()
        var known: [CorrectionDiff.Correction] = []
        let proposals = store.proposals(
            inserted: "Wir wohnen im Juringerweg", edited: "Wir wohnen im Joringelweg",
            confidences: ["juringerweg": 0.55], known: &known
        )
        #expect(proposals.map(\.replacement) == ["Joringelweg"])
    }
}
