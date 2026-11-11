import Foundation

public enum AgentKind: String, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

public enum HookAction: Equatable, Sendable {
    /// Create or refresh (heartbeat) the session lease.
    case acquire
    /// The agent finished its turn / was interrupted / the session ended.
    case release
    case ignore
}

/// Parsed JSON payload that Claude Code and Codex send to hook commands on stdin.
public struct AgentHookEvent: Equatable, Sendable {
    public var agent: AgentKind
    public var eventName: String
    public var sessionID: String?
    public var cwd: String?

    public init(agent: AgentKind, eventName: String, sessionID: String?, cwd: String?) {
        self.agent = agent
        self.eventName = eventName
        self.sessionID = sessionID
        self.cwd = cwd
    }

    /// Events that mean "the agent is working right now".
    public static let workingEvents: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "SubagentStart", "PreCompact", "PostCompact", "PreModelRequest", "PostModelRequest",
    ]
    /// Events that mean "the agent stopped working".
    public static let idleEvents: Set<String> = ["Stop", "SessionEnd", "Interrupt", "StopFailure"]

    public var action: HookAction {
        if Self.workingEvents.contains(eventName) { return .acquire }
        if Self.idleEvents.contains(eventName) { return .release }
        return .ignore
    }

    /// Parses a hook payload. Also accepts Codex `notify` payloads (`{"type":"agent-turn-complete", …}`).
    public static func parse(agent: AgentKind, json data: Data) -> AgentHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let session = (object["session_id"] ?? object["thread-id"] ?? object["thread_id"]) as? String
        let cwd = object["cwd"] as? String
        if let event = object["hook_event_name"] as? String {
            return AgentHookEvent(agent: agent, eventName: event, sessionID: session, cwd: cwd)
        }
        if (object["type"] as? String) == "agent-turn-complete" {
            return AgentHookEvent(agent: agent, eventName: "Stop", sessionID: session, cwd: cwd)
        }
        return nil
    }

    public func leaseID(fallbackPID: Int32?) -> String {
        if let sessionID, !sessionID.isEmpty { return "\(agent.rawValue)-\(sessionID)" }
        return "\(agent.rawValue)-pid\(fallbackPID ?? 0)"
    }

    /// Lease title/subtitle. `environment` lets us detect agents running inside T3 Code.
    public func presentation(environment: [String: String]) -> (label: String, detail: String?) {
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let insideT3 = environment.keys.contains { $0.hasPrefix("T3CODE_") }
        let label = insideT3 ? "T3 Code · \(agent.displayName)" : agent.displayName
        return (label, project)
    }
}
