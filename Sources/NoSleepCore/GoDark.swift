import CoreAudio
import CoreGraphics
import Foundation

/// "Go Dark": mute the sound and take the screen to black right now.
///
/// It turns the brightness all the way down, the same as holding the brightness-down key, instead of
/// putting the display to sleep. To macOS a dimmed display is still *on*, so "Require password after
/// the display is turned off" never kicks in and the session stays unlocked. That matters overnight:
/// a locked session hides every window from Accessibility, and agents can't click through dialogs.
public enum GoDark {
    /// Mutes, then dims every display that supports it. Returns the brightness to restore later.
    /// With no dimmable display (e.g. only an external monitor) it falls back to display sleep.
    @discardableResult
    public static func run() -> [DisplayBrightness.Level] {
        if !muteDefaultOutput() {
            // Some devices don't expose a mute control; let AppleScript find another way.
            run("/usr/bin/osascript", ["-e", "set volume with output muted"])
        }
        let saved = DisplayBrightness.dimAll()
        if saved.isEmpty {
            run("/usr/bin/pmset", ["displaysleepnow"])
        }
        return saved
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
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

/// Display brightness through DisplayServices, the private framework behind the brightness keys.
/// Works for built-in panels (and Apple displays); other external monitors aren't dimmable this way.
public enum DisplayBrightness {
    public struct Level: Sendable, Equatable {
        public let display: CGDirectDisplayID
        public let value: Float
    }

    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let functions: (get: GetFunction, set: SetFunction)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return (unsafeBitCast(get, to: GetFunction.self), unsafeBitCast(set, to: SetFunction.self))
    }()

    /// Current brightness (0…1) of every online display that reports one.
    public static func current() -> [Level] {
        guard let functions else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).compactMap { display in
            var value: Float = 0
            return functions.get(display, &value) == 0 ? Level(display: display, value: value) : nil
        }
    }

    /// Sets every dimmable display to zero. Returns the levels they had before.
    public static func dimAll() -> [Level] {
        guard let functions else { return [] }
        return current().filter { functions.set($0.display, 0) == 0 }
    }

    /// Brings displays back to `levels`, leaving alone any the user already turned up further.
    public static func restore(_ levels: [Level]) {
        guard let functions else { return }
        let now = Dictionary(current().map { ($0.display, $0.value) }, uniquingKeysWith: { first, _ in first })
        for level in levels where (now[level.display] ?? 0) < level.value {
            _ = functions.set(level.display, level.value)
        }
    }
}
