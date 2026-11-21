import NoSleepCore

// User-facing names for NoSleepCore values. The core stays English-only (the CLI and the agent
// hooks print it); the app translates at the edge.

extension ThermalLevel {
    var localizedName: String {
        switch self {
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Warm")
        case .serious: String(localized: "Hot")
        case .critical: String(localized: "Critical")
        }
    }
}

extension Lease {
    /// `displayTitle` with the one generic label ("Command line") translated; agent and app names stay as is.
    var localizedTitle: String {
        if (label ?? "").isEmpty, source == "cli" { return String(localized: "Command line") }
        return displayTitle
    }
}
