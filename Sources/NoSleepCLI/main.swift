import Darwin
import Foundation
import NoSleepCore

let usage = """
nosleep — keep your Mac awake from scripts and AI agents (talks to No Sleep.app)

USAGE
  nosleep for <duration>                 Keep awake for a while (e.g. 30m, 2h, 1h30m, 18:30)
  nosleep run [--label TEXT] -- <cmd…>   Keep awake while <cmd> runs
  nosleep acquire <id> [options]         Keep awake until `nosleep release <id>`
      --label TEXT    title shown in the menu
      --detail TEXT   subtitle shown in the menu
      --source NAME   origin tag (default: cli)
      --for DURATION  auto-expire after DURATION
      --pid PID       release automatically when PID exits
      --parent        release automatically when the calling process exits
  nosleep release <id>                   Drop a lease
  nosleep list                           Show active leases
  nosleep clear                          Drop all leases
  nosleep status                         Show whether the app is running
  nosleep connect claude|codex|all       Install agent hooks (Claude Code, Codex; covers T3 Code)
  nosleep disconnect claude|codex|all    Remove agent hooks
  nosleep hook claude|codex              Agent hook entry point (reads hook JSON on stdin)

"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func isAppRunning() -> Bool {
    guard let text = try? String(contentsOf: NoSleepPaths.appPIDFile, encoding: .utf8) else { return false }
    let parts = text.split(whereSeparator: \.isWhitespace)
    guard let pid = parts.first.flatMap({ Int32($0) }) else { return false }
    return ProcessInspector.isAlive(pid: pid, startTime: parts.dropFirst().first.flatMap { Double($0) })
}

func launchAppIfNeeded() {
    guard !isAppRunning() else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", NoSleepConstants.bundleIdentifier]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var rest: [String] = []
}

func parseOptions(_ args: ArraySlice<String>, valued: Set<String>, flags allowedFlags: Set<String> = []) -> Options {
    var options = Options()
    var index = args.startIndex
    while index < args.endIndex {
        let arg = args[index]
        if arg == "--" {
            options.rest = Array(args[args.index(after: index)...])
            break
        } else if valued.contains(arg) {
            let next = args.index(after: index)
            guard next < args.endIndex else { fail("\(arg) needs a value") }
            options.values[arg] = args[next]
            index = args.index(after: next)
            continue
        } else if allowedFlags.contains(arg) {
            options.flags.insert(arg)
        } else if arg.hasPrefix("--") {
            fail("Unknown option \(arg)\n\n" + usage)
        } else {
            options.positional.append(arg)
        }
        index = args.index(after: index)
    }
    return options
}

let store = LeaseStore()
let args = CommandLine.arguments
guard args.count >= 2 else {
    print(usage, terminator: "")
    exit(0)
}

let command = args[1]
let tail = args.dropFirst(2)

switch command {
case "help", "--help", "-h":
    print(usage, terminator: "")

case "acquire":
    let options = parseOptions(tail, valued: ["--label", "--detail", "--source", "--for", "--pid"], flags: ["--parent"])
    guard let id = options.positional.first else { fail("Usage: nosleep acquire <id> [options]") }
    var ttl: TimeInterval?
    if let text = options.values["--for"] {
        guard let seconds = DurationParser.duration(text) else { fail("Can't understand duration '\(text)'") }
        ttl = seconds
    }
    var pid: Int32?
    if let text = options.values["--pid"] {
        guard let value = Int32(text), ProcessInspector.snapshot(of: value) != nil else { fail("No process with pid \(text)") }
        pid = value
    } else if options.flags.contains("--parent") {
        pid = ProcessInspector.agentAncestor(startingAt: getppid())?.pid ?? getppid()
    }
    do {
        let result = try store.upsert(
            id: id, source: options.values["--source"] ?? "cli",
            label: options.values["--label"], detail: options.values["--detail"], pid: pid, ttl: ttl
        )
        LeaseStore.postChanged()
        if result.created { launchAppIfNeeded() }
        print("Keeping your Mac awake (lease '\(result.lease.id)').")
    } catch {
        fail("Could not write lease: \(error.localizedDescription)")
    }

case "for":
    guard let end = DurationParser.endDate(for: tail.joined(separator: " ")) else {
        fail("Usage: nosleep for <duration>   e.g. 45m, 2h, 1h30m, 18:30")
    }
    do {
        try store.upsert(id: "cli-timer", source: "cli", label: "Command line timer",
                         detail: "until \(end.formatted(date: .omitted, time: .shortened))",
                         ttl: end.timeIntervalSinceNow)
        LeaseStore.postChanged()
        launchAppIfNeeded()
        print("Keeping your Mac awake until \(end.formatted(date: .abbreviated, time: .shortened)).")
    } catch {
        fail("Could not write lease: \(error.localizedDescription)")
    }

case "release":
    guard let id = tail.first else { fail("Usage: nosleep release <id>") }
    let removed = store.remove(id: id)
    LeaseStore.postChanged()
    if !removed { fail("No lease named '\(id)'.") }

case "clear":
    store.removeAll()
    LeaseStore.postChanged()

case "list":
    let leases = store.pruneAndList()
    if leases.isEmpty { print("No active leases.") }
    for lease in leases {
        var line = "\(lease.id)\t\(lease.displayTitle)"
        if let detail = lease.detail { line += " — \(detail)" }
        if let expires = lease.expiresAt { line += "\t(expires \(expires.formatted(date: .omitted, time: .shortened)))" }
        if let pid = lease.pid { line += "\t[pid \(pid)]" }
        print(line)
    }

case "status":
    let leases = store.pruneAndList()
    print("No Sleep.app: \(isAppRunning() ? "running" : "not running")")
    print("Active leases: \(leases.count)")

case "run":
    let options = parseOptions(tail, valued: ["--label"])
    let commandLine = options.rest.isEmpty ? options.positional : options.rest
    guard !commandLine.isEmpty else { fail("Usage: nosleep run [--label TEXT] -- <command> [args…]") }
    let id = "run-\(getpid())"
    let label = options.values["--label"] ?? commandLine.joined(separator: " ")
    _ = try? store.upsert(id: id, source: "cli", label: String(label.prefix(60)),
                          detail: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent,
                          pid: getpid())
    LeaseStore.postChanged()
    launchAppIfNeeded()

    // Let the child decide what to do with ^C; we just wait and clean up.
    // (A no-op handler — unlike SIG_IGN — is reset to default for the child on exec.)
    signal(SIGINT) { _ in }
    signal(SIGTERM) { _ in }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = commandLine
    var status: Int32 = 127
    do {
        try process.run()
        process.waitUntilExit()
        status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    } catch {
        FileHandle.standardError.write("nosleep: \(error.localizedDescription)\n".data(using: .utf8)!)
    }
    store.remove(id: id)
    LeaseStore.postChanged()
    exit(status)

case "connect", "disconnect":
    let target = tail.first ?? ""
    let agents: [AgentKind] = target == "all" ? AgentKind.allCases : AgentKind(rawValue: target).map { [$0] } ?? []
    guard !agents.isEmpty else { fail("Usage: nosleep \(command) claude|codex|all") }
    // Hooks call this very binary (resolved, so a ~/.local/bin symlink works too).
    let cliPath = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath().path
    for agent in agents {
        let installer = HookInstaller(agent: agent, cliPath: cliPath)
        do {
            if command == "connect" { try installer.install() } else { try installer.uninstall() }
            print("\(agent.displayName): \(command == "connect" ? "connected" : "disconnected") (\(installer.configURL.path))")
        } catch {
            fail("\(agent.displayName): \(error)")
        }
    }
    if command == "connect", agents.contains(.codex) {
        print("Codex will ask you to review the new hooks the next time it starts.")
    }

case "hook":
    // Must never break the agent: no stdout, always exit 0.
    guard let agentName = tail.first, let agent = AgentKind(rawValue: agentName) else { exit(0) }
    var payload = Data()
    if let inline = tail.dropFirst().last, inline.hasPrefix("{") {
        payload = Data(inline.utf8) // Codex `notify` passes JSON as an argument.
    } else if isatty(STDIN_FILENO) == 0 {
        payload = FileHandle.standardInput.readDataToEndOfFile()
    }
    guard let event = AgentHookEvent.parse(agent: agent, json: payload) else { exit(0) }

    let environment = ProcessInfo.processInfo.environment
    var agentPID: Int32?
    if agent == .claude, let value = environment["CLAUDE_PID"].flatMap(Int32.init),
       ProcessInspector.snapshot(of: value) != nil {
        agentPID = value
    } else {
        agentPID = ProcessInspector.agentAncestor(startingAt: getppid())?.pid
    }
    let id = event.leaseID(fallbackPID: agentPID)

    switch event.action {
    case .acquire:
        let presentation = event.presentation(environment: environment)
        if let result = try? store.upsert(
            id: id, source: agent.rawValue, label: presentation.label, detail: presentation.detail,
            pid: agentPID, ttl: AgentIdleTimeout.current
        ) {
            if result.created {
                LeaseStore.postChanged()
                launchAppIfNeeded()
            }
        }
    case .release:
        if store.remove(id: id) { LeaseStore.postChanged() }
    case .ignore:
        break
    }
    exit(0)

default:
    fail("Unknown command '\(command)'.\n\n" + usage)
}
