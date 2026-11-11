import Foundation

public enum NoSleepConstants {
    public static let bundleIdentifier = "com.tomaspinausig.nosleep"
    /// Darwin notification posted by the CLI whenever a lease changes.
    public static let leasesChangedNotification = "com.tomaspinausig.nosleep.leases-changed"
    /// Preference key (in the app's defaults domain) read by the CLI for agent lease TTL.
    public static let agentIdleTimeoutKey = "agentIdleTimeoutMinutes"
    public static let defaultAgentIdleTimeoutMinutes = 60
}

public enum NoSleepPaths {
    /// `~/Library/Application Support/NoSleep`. Overridable with `NOSLEEP_HOME` (used by tests).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["NOSLEEP_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NoSleep", isDirectory: true)
    }

    public static var leasesDirectory: URL {
        supportDirectory.appendingPathComponent("leases", isDirectory: true)
    }

    /// The running app writes `pid starttime` here so the CLI can tell whether it is running.
    public static var appPIDFile: URL {
        supportDirectory.appendingPathComponent("app.pid")
    }
}

public enum AgentIdleTimeout {
    /// Reads the TTL configured in the app (shared defaults domain), falling back to the default.
    public static var current: TimeInterval {
        let value = CFPreferencesCopyAppValue(
            NoSleepConstants.agentIdleTimeoutKey as CFString,
            NoSleepConstants.bundleIdentifier as CFString
        )
        let minutes = (value as? NSNumber)?.intValue ?? NoSleepConstants.defaultAgentIdleTimeoutMinutes
        return TimeInterval(max(1, minutes) * 60)
    }
}
