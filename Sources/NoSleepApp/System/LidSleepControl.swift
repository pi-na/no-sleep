import Foundation
import IOKit

/// Controls `pmset -a disablesleep`, the only switch that keeps a MacBook awake with the lid closed.
///
/// `pmset` needs root, so on first use we ask once for admin rights to install a sudoers rule that
/// allows *only* `pmset -a disablesleep 0|1` without a password. After that, toggling is silent.
enum LidSleepControl {
    static let sudoersPath = "/etc/sudoers.d/nosleep"
    static let pmsetPath = "/usr/bin/pmset"

    enum SetupError: LocalizedError {
        case cancelled
        case unsupportedUserName
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Setup was cancelled."
            case .unsupportedUserName: return "Your user name contains characters No Sleep can't safely write to sudoers."
            case .failed(let message): return message
            }
        }
    }

    static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// Current `SleepDisabled` value reported by `pmset -g`, if it could be read.
    static func isSleepDisabled() -> Bool? {
        let result = run(pmsetPath, ["-g"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" { return fields[1] == "1" }
        }
        return nil
    }

    /// Runs `sudo -n pmset -a disablesleep N`. Returns false if sudo refused (rule missing) or pmset failed.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
    }

    /// True when the lid is closed and macOS would sleep because of it (no external display).
    /// With `disablesleep 1` macOS reports `AppleClamshellCausesSleep = No`, so read it *after* restoring.
    static func closedLidWouldSleep() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        func flag(_ key: String) -> Bool {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) ?? false
        }
        return flag("AppleClamshellState") && flag("AppleClamshellCausesSleep")
    }

    /// Normal sleep was just restored: if the lid is already closed, sleep now instead of
    /// waiting for macOS to notice (it doesn't re-check the lid until something changes).
    static func sleepIfLidClosed() {
        Thread.sleep(forTimeInterval: 1)
        if closedLidWouldSleep() {
            run(pmsetPath, ["sleepnow"])
        }
    }

    static func sudoersRule(for user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1"
    }

    /// Shows the macOS admin prompt and installs the sudoers rule (validated with `visudo`).
    /// If `apply` is set, also applies that value in the same privileged call.
    static func installHelper(apply: Bool?) throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw SetupError.unsupportedUserName
        }
        var script = """
        set -e
        /bin/mkdir -p /private/etc/sudoers.d
        tmp=$(/usr/bin/mktemp /private/etc/sudoers.d/.nosleep.XXXXXX)
        trap '/bin/rm -f "$tmp"' EXIT
        /usr/bin/printf '%s\\n' '# Installed by No Sleep.app - lets this user toggle pmset disablesleep.' '\(sudoersRule(for: user))' > "$tmp"
        /usr/sbin/visudo -cf "$tmp" >/dev/null
        /usr/sbin/chown root:wheel "$tmp"
        /bin/chmod 0440 "$tmp"
        /bin/mv -f "$tmp" \(sudoersPath)
        """
        if let apply {
            script += "\n\(pmsetPath) -a disablesleep \(apply ? 1 : 0)"
        }
        try runAsAdmin(script, prompt: "No Sleep needs permission to keep your Mac awake when the lid is closed. You'll only be asked once.")
    }

    static func uninstallHelper() throws {
        try runAsAdmin(
            "/bin/rm -f \(sudoersPath); \(pmsetPath) -a disablesleep 0",
            prompt: "No Sleep wants to remove its permission to change sleep settings."
        )
    }

    private static func runAsAdmin(_ shellScript: String, prompt: String) throws {
        func appleScriptString(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(appleScriptString(shellScript)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", source])
        guard result.status == 0 else {
            if result.output.contains("-128") { throw SetupError.cancelled }
            throw SetupError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
