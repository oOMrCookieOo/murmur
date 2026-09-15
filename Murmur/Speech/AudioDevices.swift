import AVFoundation
import CoreAudio
import Foundation

/// An audio input the user can dictate through.
struct AudioInputDevice: Identifiable, Sendable, Hashable {
    /// CoreAudio's transient numeric id. Valid only for this boot, which is why
    /// the *UID* is what gets persisted.
    let id: AudioDeviceID
    /// Stable across reboots and reconnections.
    let uid: String
    let name: String
}

/// Enumerates microphones and resolves a saved choice back to a live device.
///
/// `AVCaptureDevice` can list microphones but does not hand back the
/// `AudioDeviceID` that `AVAudioEngine` needs to be pointed at one, so this
/// talks to CoreAudio directly.
enum AudioDevices {

    /// Every device that currently has at least one input channel.
    static func inputs() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: id),
                  let name = stringProperty(kAudioObjectPropertyName, for: id)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func device(uid: String) -> AudioInputDevice? {
        inputs().first { $0.uid == uid }
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids
    }

    /// Output-only devices show up in the same list, so input channels are what
    /// distinguishes a microphone from a pair of speakers.
    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for id: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
