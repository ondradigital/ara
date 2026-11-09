import FluidAudio

/// Parakeet Ultra running on the Neural Engine through FluidAudio.
actor ParakeetEngine: SpeechEngine {
    /// Parakeet rejects anything shorter than this.
    static let minimumDuration = ASRConstants.minimumAudioDurationSeconds

    private var manager: AsrManager?

    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .ultra) { progress in
            onProgress(progress.fractionCompleted)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        guard let manager else { throw ASRError.notInitialized }
        // Every dictation is independent, so each one starts from a fresh decoder state.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        // The model writes <unk> for sounds it has no token for.
        let text = result.text.replacingOccurrences(of: "<unk>", with: "")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return Transcript(text: text, wordConfidences: Self.wordConfidences(from: result.tokenTimings ?? []))
    }

    /// Groups the SentencePiece pieces into words (a piece starting with "▁"
    /// or a space begins a new word) and keeps each word's weakest piece.
    private nonisolated static func wordConfidences(from timings: [TokenTiming]) -> [String: Float] {
        var confidences: [String: Float] = [:]
        var word = ""
        var lowest: Float = 1

        func finish() {
            for part in CorrectionDiff.words(in: word) {
                let key = part.lowercased()
                confidences[key] = min(confidences[key] ?? 1, lowest)
            }
        }

        for timing in timings {
            let piece = timing.token
            guard !piece.isEmpty, piece != "<blank>", piece != "<pad>", piece != "<unk>" else { continue }
            if piece.hasPrefix("▁") || piece.hasPrefix(" ") {
                finish()
                word = String(piece.drop(while: { $0 == "▁" || $0 == " " }))
                lowest = timing.confidence
            } else {
                word += piece
                lowest = min(lowest, timing.confidence)
            }
        }
        finish()
        return confidences
    }
}
