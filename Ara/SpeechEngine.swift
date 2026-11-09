/// A speech-to-text model. The app talks to every engine through this
/// protocol so engines can be swapped and compared on the same recordings.
protocol SpeechEngine: Sendable {
    /// Loads the model into memory, downloading it on first use.
    /// `onProgress` receives the download fraction from 0 to 1.
    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcribes 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float]) async throws -> Transcript
}

/// What the engine heard, and how sure it was of each word.
struct Transcript: Sendable {
    var text: String
    /// The lowest confidence (0 to 1) among each word's pieces, keyed by the
    /// word in lowercase without surrounding punctuation. Empty when the
    /// engine does not report confidences.
    var wordConfidences: [String: Float] = [:]
}
