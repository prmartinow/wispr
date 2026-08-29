import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Lists audio input devices (via AVFoundation) and switches the system default input
/// (via CoreAudio). The mic picker sets the default input — the same thing System
/// Settings ▸ Sound does — which AVAudioRecorder then records from.
enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        // devices(for:) is deprecated but is the version-safe way to list audio inputs on
        // macOS 13 (the typed DiscoverySession audio cases are macOS 14+).
        AVCaptureDevice.devices(for: .audio)
            .map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    static func setDefaultInput(uid: String) {
        guard let deviceID = deviceID(forUID: uid) else { return }
        var id = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        return deviceID
    }

    static func setInputVolume(percent: Float = 89.0) {
        guard let deviceID = defaultInputDeviceID() else { return }
        var vol: Float32 = max(0.0, min(1.0, percent / 100.0))
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: UInt32(element))
            if AudioObjectHasProperty(deviceID, &addr) {
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr && settable.boolValue {
                    AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
                }
            }
        }
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return nil }
        return ids.first { uidString(for: $0) == uid }
    }

    private static func uidString(for id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
              let value = cf?.takeRetainedValue() else { return nil }
        return value as String
    }
}
