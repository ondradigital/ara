/// A speech-to-text model. The app talks to every engine through this
/// protocol so engines can be swapped and compared on the same recordings.
protocol SpeechEngine: Sendable {
    /// Loads the model into memory, downloading it on first use.
    /// `onProgress` receives the download fraction from 0 to 1.
    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcribes 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float]) async throws -> String
}
