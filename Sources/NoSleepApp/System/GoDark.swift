import CoreAudio
import Foundation

/// "Go Dark": mute the sound and turn the screen off right now (any key or mouse move wakes the screen).
enum GoDark {
    static func run() {
        if !muteDefaultOutput() {
            // Some devices don't expose a mute control; let AppleScript find another way.
            LidSleepControl.run("/usr/bin/osascript", ["-e", "set volume with output muted"])
        }
        LidSleepControl.run(LidSleepControl.pmsetPath, ["displaysleepnow"])
    }

    /// Mutes the current default output device through CoreAudio.
    private static func muteDefaultOutput() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultDevice = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return false }

        var mute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &mute),
              AudioObjectIsPropertySettable(deviceID, &mute, &settable) == noErr, settable.boolValue
        else { return false }
        var value: UInt32 = 1
        return AudioObjectSetPropertyData(deviceID, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
