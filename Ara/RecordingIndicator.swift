import Observation
import SwiftUI

/// The most recent microphone loudness values, oldest first, for the waveform.
@Observable
final class LevelMeter {
    static let barCount = 24

    private(set) var levels = [Float](repeating: 0, count: barCount)

    func append(_ newLevels: [Float]) {
        levels = Array((levels + newLevels).suffix(Self.barCount))
    }

    func reset() {
        levels = [Float](repeating: 0, count: Self.barCount)
    }
}

/// The pill shown while recording: a waveform that follows the voice.
struct RecordingIndicatorView: View {
    let meter: LevelMeter

    private static let minBarHeight: CGFloat = 3
    private static let maxBarHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(meter.levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(
                        width: 3,
                        height: Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(meter.levels[index])
                    )
            }
        }
        .frame(height: Self.maxBarHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.black.opacity(0.85), in: .capsule)
        .animation(.easeOut(duration: 0.1), value: meter.levels)
    }
}

/// A short message in the style of the recording pill, for things the user
/// should know right now, such as text that was left on the clipboard.
struct NoticeView: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.85), in: .capsule)
    }
}
