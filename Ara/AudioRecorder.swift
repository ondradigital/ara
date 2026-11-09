import Accelerate
import AVFoundation
import CoreAudio
import os

/// Captures the default microphone as 16 kHz mono Float32, the input format
/// of the speech models.
///
/// Each recording reads the input device directly through Core Audio and
/// leaves nothing behind. An `AVAudioEngine` kept for the next recording
/// follows every change of the audio devices on its own, and replacing it
/// after such a change could leave the app stuck in `inputNode` for good
/// (macOS 27.0.1).
nonisolated final class AudioRecorder {
    enum RecorderError: Error {
        case noInputDevice
        case converterUnavailable
        case deviceFailed(OSStatus)
    }

    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    /// Receives the loudness (0 to 1) of each 20 ms of input while
    /// recording, for the waveform. Called on an audio thread.
    var onLevels: (@Sendable ([Float]) -> Void)?

    private var capture: Capture?

    func start() throws {
        capture = try Capture(onLevels: onLevels)
    }

    /// Stops capturing and returns everything recorded since `start()`.
    func stop() -> [Float] {
        defer { capture = nil }
        return capture?.stop() ?? []
    }

    /// One recording: the callback on the input device and what it has
    /// collected so far.
    private nonisolated final class Capture: @unchecked Sendable {
        private struct Progress {
            var samples: [Float] = []
            /// Changes when the device is switched to another rate while it runs.
            var sampleRate: Double
        }

        private let device: AudioDeviceID
        private let onLevels: (@Sendable ([Float]) -> Void)?
        private let progress: OSAllocatedUnfairLock<Progress>
        private var ioProc: AudioDeviceIOProcID?
        private var rateListener: AudioObjectPropertyListenerBlock?
        private let logger = Logger(subsystem: "com.erikondra.Ara", category: "audio")

        // Once the device runs, only its IO thread touches these.
        private var converter: AVAudioConverter
        private var levelSquares: Float = 0
        private var levelFrames = 0

        init(onLevels: (@Sendable ([Float]) -> Void)?) throws {
            guard let device = Self.read(Self.defaultInputAddress, of: AudioObjectID(kAudioObjectSystemObject), as: AudioDeviceID.self),
                device != kAudioObjectUnknown,
                let sampleRate = Self.read(Self.sampleRateAddress, of: device, as: Float64.self),
                sampleRate > 0
            else { throw RecorderError.noInputDevice }
            guard let converter = Self.converter(fromSampleRate: sampleRate) else {
                throw RecorderError.converterUnavailable
            }

            self.device = device
            self.onLevels = onLevels
            self.converter = converter
            progress = OSAllocatedUnfairLock(initialState: Progress(sampleRate: sampleRate))

            var ioProc: AudioDeviceIOProcID?
            var status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil) { [weak self] _, input, _, output, _ in
                // A device that also plays sound hands over its output buffers, which have to stay silent.
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                self?.process(input)
            }
            guard status == noErr, let ioProc else { throw RecorderError.deviceFailed(status) }
            self.ioProc = ioProc

            let rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.sampleRateDidChange()
            }
            var address = Self.sampleRateAddress
            if AudioObjectAddPropertyListenerBlock(device, &address, nil, rateListener) == noErr {
                self.rateListener = rateListener
            }

            // A throw from here on still runs `deinit`, which takes the callback and the listener away again.
            status = AudioDeviceStart(device, ioProc)
            guard status == noErr else { throw RecorderError.deviceFailed(status) }
            logger.notice("recording from \(Self.name(of: device), privacy: .public) at \(sampleRate, privacy: .public) Hz")
        }

        deinit {
            _ = stop()
        }

        /// Ends the recording and returns what it collected.
        func stop() -> [Float] {
            if let ioProc {
                AudioDeviceStop(device, ioProc)
                AudioDeviceDestroyIOProcID(device, ioProc)
                self.ioProc = nil
            }
            if let rateListener {
                var address = Self.sampleRateAddress
                AudioObjectRemovePropertyListenerBlock(device, &address, nil, rateListener)
                self.rateListener = nil
            }
            return progress.withLock { $0.samples }
        }

        private func sampleRateDidChange() {
            guard let sampleRate = Self.read(Self.sampleRateAddress, of: device, as: Float64.self), sampleRate > 0 else { return }
            progress.withLock { $0.sampleRate = sampleRate }
            logger.notice("input device switched to \(sampleRate, privacy: .public) Hz while recording")
        }

        /// Called on the device's IO thread with every few milliseconds of input.
        private func process(_ input: UnsafePointer<AudioBufferList>) {
            // The first stream is the microphone; Core Audio hands it over as interleaved Float32.
            let buffer = input.pointee.mBuffers
            let channels = Int(buffer.mNumberChannels)
            guard input.pointee.mNumberBuffers > 0, channels > 0, let data = buffer.mData else { return }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)

            let sampleRate = progress.withLock { $0.sampleRate }
            if sampleRate != converter.inputFormat.sampleRate {
                guard let converter = Self.converter(fromSampleRate: sampleRate) else { return }
                self.converter = converter
                levelSquares = 0
                levelFrames = 0
            }

            guard frames > 0,
                let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
                let channel = mono.floatChannelData?[0]
            else { return }
            mono.frameLength = AVAudioFrameCount(frames)

            // Mixed down to mono: the mean of all channels.
            let interleaved = data.assumingMemoryBound(to: Float.self)
            var share = 1 / Float(channels)
            vDSP_vsmul(interleaved, channels, &share, channel, 1, vDSP_Length(frames))
            for index in 1..<channels {
                vDSP_vsma(interleaved + index, channels, &share, channel, 1, channel, 1, vDSP_Length(frames))
            }

            reportLevels(of: UnsafeBufferPointer(start: channel, count: frames), chunkSize: Int(sampleRate / 50))

            let ratio = AudioRecorder.format.sampleRate / sampleRate
            let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: AudioRecorder.format, frameCapacity: capacity) else {
                return
            }

            // The converter pulls its input through this block; hand it the
            // buffer once, then report that no more data is available.
            nonisolated(unsafe) var pending: AVAudioPCMBuffer? = mono
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                status.pointee = pending == nil ? .noDataNow : .haveData
                defer { pending = nil }
                return pending
            }

            guard error == nil, let output = converted.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: output, count: Int(converted.frameLength)))
            progress.withLock { $0.samples.append(contentsOf: chunk) }
        }

        /// Hands on one loudness value per chunk: 0 at room noise (−50 dB),
        /// 1 at loud speech (−10 dB). The device delivers less than a chunk
        /// at a time, so a value is gathered across several calls.
        private func reportLevels(of samples: UnsafeBufferPointer<Float>, chunkSize: Int) {
            guard let onLevels, let base = samples.baseAddress, chunkSize > 0 else { return }
            var levels: [Float] = []
            var offset = 0
            while offset < samples.count {
                let count = min(chunkSize - levelFrames, samples.count - offset)
                var squares: Float = 0
                vDSP_svesq(base + offset, 1, &squares, vDSP_Length(count))
                levelSquares += squares
                levelFrames += count
                offset += count
                guard levelFrames == chunkSize else { break }

                let decibels = 10 * log10(max(levelSquares / Float(chunkSize), 1e-14))
                levels.append(min(max((decibels + 50) / 40, 0), 1))
                levelSquares = 0
                levelFrames = 0
            }
            if !levels.isEmpty {
                onLevels(levels)
            }
        }

        private static func converter(fromSampleRate sampleRate: Double) -> AVAudioConverter? {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
                .flatMap { AVAudioConverter(from: $0, to: AudioRecorder.format) }
        }

        // MARK: - Core Audio

        private static let defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private static let sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        private static func name(of device: AudioDeviceID) -> String {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else {
                return "device \(device)"
            }
            return name.takeRetainedValue() as String
        }

        private static func read<Value>(_ address: AudioObjectPropertyAddress, of object: AudioObjectID, as type: Value.Type) -> Value? {
            var address = address
            var size = UInt32(MemoryLayout<Value>.size)
            let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
            defer { value.deallocate() }
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
            return value.pointee
        }
    }
}
