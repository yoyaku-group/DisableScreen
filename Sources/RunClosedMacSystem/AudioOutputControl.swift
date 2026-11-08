import Foundation
import CoreAudio
import RunClosedPersistence

/// Muting the default audio output, with everything the undo needs recorded
/// before the write (ADR 026).
///
/// The layer is split in two on purpose:
///
/// - `AudioOutputBackend` is the ONLY thing that talks to CoreAudio. It is a
///   protocol so the tests drive `LidCloseActionService` on fakes and never
///   mute the operator's Mac.
/// - The service decides WHAT to record and WHEN; this type only reports
///   observations honestly (`nil` = could not read, never a guessed value).
///
/// Why the device UID and not the `AudioObjectID`: the id is a per-process
/// handle. It changes when the process restarts and when the device is
/// re-plugged, so a journal holding only the id could not find the device it
/// muted. The UID names the physical output across both.
public protocol AudioOutputBackend: Sendable {
    /// The current default output device, with the state we would have to
    /// restore. `nil` = no device / unreadable — nothing may be muted.
    func readDefaultOutput() -> AudioOutputSnapshot?

    /// Look a device up by UID. `nil` = the device is gone, which the undo
    /// treats as "nothing to restore and not an error".
    func readOutput(uid: String) -> AudioOutputSnapshot?

    /// Mute `uid`. Returns whether the write was ACCEPTED. Acceptance is not
    /// proof (ADR 009) — the caller re-reads with `readOutput(uid:)`.
    @discardableResult
    func setMuted(_ muted: Bool, uid: String) -> Bool
}

/// One observation of an output device.
public struct AudioOutputSnapshot: Equatable, Sendable {
    public var uid: String
    /// `true` = muted right now. `false` = audible.
    public var isMuted: Bool
    /// The output volume scalar, when the device reports a settable one.
    /// `nil` = no volume property, so only the mute flag belongs to us.
    public var volume: Float?
    /// Whether the device accepts a mute write. A device that cannot be muted
    /// must be reported as such rather than "muted successfully".
    public var canMute: Bool

    public init(uid: String, isMuted: Bool, volume: Float?, canMute: Bool) {
        self.uid = uid
        self.isMuted = isMuted
        self.volume = volume
        self.canMute = canMute
    }
}

/// Live CoreAudio backend (default output device only).
///
/// Uses the public `kAudioHardwarePropertyDefaultOutputDevice` + device
/// properties (`kAudioDevicePropertyMute`, `kAudioDevicePropertyVolumeScalar`).
/// No private API, no privilege, no subprocess.
public struct CoreAudioOutputBackend: AudioOutputBackend {

    public init() {}

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// The default output device, or `nil` when the system reports none.
    public func defaultOutputDeviceID() -> AudioObjectID? {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let rc = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard rc == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// UID of a device. `nil` when it does not report one (some aggregate
    /// devices do not), in which case the caller must not mute: an effect it
    /// cannot name is an effect it cannot undo.
    public func uid(of device: AudioObjectID) -> String? {
        var addr = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let rc = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard rc == noErr else { return nil }
        let text = uid as String
        return text.isEmpty ? nil : text
    }

    /// Every device whose UID matches `uid`. `kAudioHardwarePropertyTranslateUIDToDevice`
    /// is the documented path, but it takes the UID as `CFString` and is fussy
    /// about the qualifier; enumerating the devices is portable, and the list is
    /// small (a handful of outputs on any Mac).
    public func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
        else { return nil }
        return devices.first { self.uid(of: $0) == uid }
    }

    public func snapshot(of device: AudioObjectID) -> AudioOutputSnapshot? {
        guard let uid = uid(of: device) else { return nil }
        var muteAddr = Self.address(kAudioDevicePropertyMute,
                                    scope: kAudioObjectPropertyScopeOutput)
        var settable = DarwinBoolean(false)
        let settableRC = AudioObjectIsPropertySettable(device, &muteAddr, &settable)
        // `AudioObjectHasProperty` RETURNS the answer; it takes no out-param.
        // An earlier version declared a local `DarwinBoolean(false)` and ANDed
        // it in, which made `canMute` permanently false and the whole audio
        // action a silent no-op (caught by ai-review-gate). There is no
        // "out-param" spelling to keep: the return value IS the property.
        let hasRC = AudioObjectHasProperty(device, &muteAddr)
        var muted = UInt32(0)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteRC = AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &muteSize, &muted)
        let canMute = settableRC == noErr && hasRC && settable.boolValue && muteRC == noErr

        // `muteRC != noErr` means the device has no readable mute flag. Report
        // `isMuted: false` and `canMute: false` rather than inventing a state:
        // the service refuses to act on a device whose prior state it does not
        // know, because the undo would be a guess.
        return AudioOutputSnapshot(
            uid: uid,
            isMuted: canMute ? muted != 0 : false,
            volume: volume(of: device),
            canMute: canMute)
    }

    /// `kAudioDevicePropertyVolumeScalar` on the main output element. `nil`
    /// when the device does not report one.
    public func volume(of device: AudioObjectID) -> Float? {
        var addr = Self.address(kAudioDevicePropertyVolumeScalar,
                                scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    public func readDefaultOutput() -> AudioOutputSnapshot? {
        guard let device = defaultOutputDeviceID() else { return nil }
        return snapshot(of: device)
    }

    public func readOutput(uid: String) -> AudioOutputSnapshot? {
        guard let device = deviceID(forUID: uid) else { return nil }
        return snapshot(of: device)
    }

    @discardableResult
    public func setMuted(_ muted: Bool, uid: String) -> Bool {
        guard let device = deviceID(forUID: uid) else { return false }
        var addr = Self.address(kAudioDevicePropertyMute,
                                scope: kAudioObjectPropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == noErr
    }
}
