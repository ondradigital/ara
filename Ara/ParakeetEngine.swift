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

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        // Every dictation is independent, so each one starts from a fresh decoder state.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }
}
