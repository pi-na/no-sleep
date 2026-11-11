import Foundation

/// Adds/removes No Sleep's hook commands in Claude Code (`~/.claude/settings.json`)
/// and Codex (`~/.codex/hooks.json`). Both use the same `{"hooks": {Event: [{hooks:[…]}]}}` schema.
public struct HookInstaller {
    public let agent: AgentKind
    public let configURL: URL
    public let cliPath: String

    public init(agent: AgentKind, cliPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.agent = agent
        self.cliPath = cliPath
        switch agent {
        case .claude: configURL = home.appendingPathComponent(".claude/settings.json")
        case .codex: configURL = home.appendingPathComponent(".codex/hooks.json")
        }
    }

    public var events: [String] {
        switch agent {
        case .claude: return ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
        case .codex: return ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
        }
    }

    /// Seconds. Codex clamps some events (SessionEnd, Interrupt) to 3s; our hook takes milliseconds.
    public var command: String {
        "\(Self.shellQuote(cliPath)) hook \(agent.rawValue)"
    }

    public static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+~")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Our entries are recognised by shape, so a moved app bundle is still cleaned up.
    func isOurs(_ hook: JSONValue) -> Bool {
        guard let command = hook["command"]?.stringValue else { return false }
        return command.contains("nosleep") && command.hasSuffix(" hook \(agent.rawValue)")
    }

    public enum Status: Equatable {
        case notInstalled
        case installed
        /// Installed, but pointing at a different binary path (e.g. the app moved).
        case outdated
    }

    public func status() -> Status {
        guard let root = try? load(), let hooks = root["hooks"] else { return .notInstalled }
        var found = 0
        var current = 0
        for event in events {
            for group in hooks[event]?.arrayValue ?? [] {
                for hook in group["hooks"]?.arrayValue ?? [] where isOurs(hook) {
                    found += 1
                    if hook["command"]?.stringValue == command { current += 1 }
                }
            }
        }
        if found == 0 { return .notInstalled }
        return current >= events.count ? .installed : .outdated
    }

    func load() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .object([]) }
        let text = try String(contentsOf: configURL, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .object([]) }
        let value = try JSONValue.parse(text)
        guard value.isObject else {
            throw JSONValue.ParseError(message: "top-level value is not an object", offset: 0)
        }
        return value
    }

    /// Returns `root` with our hooks removed (and empty containers cleaned up).
    func removingOurs(from root: JSONValue) -> JSONValue {
        var root = root
        guard case .object(var eventMembers)? = root["hooks"] else { return root }
        eventMembers = eventMembers.compactMap { member in
            guard case .array(let groups) = member.value else { return member }
            let cleaned: [JSONValue] = groups.compactMap { group in
                guard case .array(let hooks)? = group["hooks"] else { return group }
                let kept = hooks.filter { !isOurs($0) }
                if kept.count == hooks.count { return group }
                if kept.isEmpty { return nil }
                var group = group
                group["hooks"] = .array(kept)
                return group
            }
            return cleaned.isEmpty ? nil : JSONValue.Member(member.key, .array(cleaned))
        }
        root["hooks"] = eventMembers.isEmpty ? nil : .object(eventMembers)
        return root
    }

    func installing(into root: JSONValue) -> JSONValue {
        var root = removingOurs(from: root)
        var hooks = root["hooks"] ?? .object([])
        let entry: JSONValue = .object([
            .init("hooks", .array([
                .object([
                    .init("type", .string("command")),
                    .init("command", .string(command)),
                    .init("timeout", .number(agent == .codex ? "3" : "10")),
                ]),
            ])),
        ])
        for event in events {
            var groups = hooks[event]?.arrayValue ?? []
            groups.append(entry)
            hooks[event] = .array(groups)
        }
        root["hooks"] = hooks
        return root
    }

    public func install() throws {
        try write(installing(into: try load()))
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        try write(removingOurs(from: try load()))
    }

    private func write(_ root: JSONValue) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One-time backup of the user's original file.
        let backup = configURL.appendingPathExtension("nosleep-backup")
        if fileManager.fileExists(atPath: configURL.path), !fileManager.fileExists(atPath: backup.path) {
            try? fileManager.copyItem(at: configURL, to: backup)
        }
        try (root.serialized() + "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }
}
