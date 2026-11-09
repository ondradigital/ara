import AudioToolbox
import CoreAudio
import Foundation

/// Silences the default output device while a recording runs, so music or
/// video sound does not leak into the microphone.
///
/// macOS has no public API to pause other apps' playback, so this mutes the
/// device instead and puts it back exactly as it was.
final class OutputMuter {
    /// What was changed, so it can be undone. It is also persisted, because a
    /// crash during a recording would otherwise leave the Mac silent.
    private struct Change: Codable {
        var deviceUID: String
        /// The volume to return to, for devices that have no mute switch.
        var previousVolume: Float32?
    }

    private static let defaultsKey = "outputMuterPendingChange"
    private var change: Change?

    func mute() {
        guard change == nil, let device = Self.defaultOutputDevice(), let uid = Self.uid(of: device) else { return }

        if let muted = Self.read(Self.muteAddress, of: device, as: UInt32.self), Self.isSettable(Self.muteAddress, of: device) {
            // Already muted by the user: leave it, and leave it muted afterwards.
            guard muted == 0, Self.write(UInt32(1), to: Self.muteAddress, of: device) else { return }
            remember(Change(deviceUID: uid))
        } else if let volume = Self.read(Self.volumeAddress, of: device, as: Float32.self),
            Self.isSettable(Self.volumeAddress, of: device)
        {
            guard volume > 0, Self.write(Float32(0), to: Self.volumeAddress, of: device) else { return }
            remember(Change(deviceUID: uid, previousVolume: volume))
        }
        // Devices with neither control (HDMI displays, for example) are left as they are.
    }

    func restore() {
        guard let change else { return }
        Self.undo(change)
        self.change = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    /// Undoes a mute that an earlier run of the app did not get to restore.
    func restoreAfterUncleanExit() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        if let change = try? JSONDecoder().decode(Change.self, from: data) {
            Self.undo(change)
        }
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func remember(_ change: Change) {
        self.change = change
        UserDefaults.standard.set(try? JSONEncoder().encode(change), forKey: Self.defaultsKey)
    }

    /// Restores the device that was muted, even if the default output changed
    /// in the meantime. A device that has been unplugged is skipped.
    private static func undo(_ change: Change) {
        guard let device = device(withUID: change.deviceUID) else { return }
        if let volume = change.previousVolume {
            write(volume, to: volumeAddress, of: device)
        } else {
            write(UInt32(0), to: muteAddress, of: device)
        }
    }

    // MARK: - Core Audio

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDevice() -> AudioDeviceID? {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let device = read(address, of: AudioObjectID(kAudioObjectSystemObject), as: AudioDeviceID.self),
            device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func device(withUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device
            )
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func read<Value>(_ address: AudioObjectPropertyAddress, of object: AudioObjectID, as type: Value.Type) -> Value? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func isSettable(_ address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    private static func write<Value>(_ value: Value, to address: AudioObjectPropertyAddress, of object: AudioObjectID) -> Bool {
        var address = address
        return withUnsafeBytes(of: value) { bytes in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(bytes.count), bytes.baseAddress!) == noErr
        }
    }
}
