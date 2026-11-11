import Foundation

/// A request from outside the app (an agent hook, the CLI…) to keep the Mac awake.
/// Leases live as JSON files in `NoSleepPaths.leasesDirectory`.
public struct Lease: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// Machine-readable origin: `claude`, `codex`, `cli`, …
    public var source: String
    /// Human-readable title, e.g. "Claude Code".
    public var label: String?
    /// Secondary text, e.g. the project folder.
    public var detail: String?
    /// When set, the lease dies with this process.
    public var pid: Int32?
    public var pidStartTime: Double?
    public var createdAt: Date
    public var updatedAt: Date
    /// When set, the lease is ignored (and pruned) after this date.
    public var expiresAt: Date?

    public init(
        id: String, source: String, label: String? = nil, detail: String? = nil,
        pid: Int32? = nil, pidStartTime: Double? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(), expiresAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.detail = detail
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    public enum Validity: Equatable, Sendable {
        case valid
        case expired
        case processGone
    }

    public func validity(
        now: Date = Date(),
        isProcessAlive: (Int32, Double?) -> Bool = ProcessInspector.isAlive
    ) -> Validity {
        if let expiresAt, expiresAt <= now { return .expired }
        if let pid, !isProcessAlive(pid, pidStartTime) { return .processGone }
        return .valid
    }

    public var displayTitle: String {
        if let label, !label.isEmpty { return label }
        switch source {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cli": return "Command line"
        default: return source.capitalized
        }
    }
}
