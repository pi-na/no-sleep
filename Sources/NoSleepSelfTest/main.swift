import Foundation
import NoSleepCore

// Lightweight test runner (XCTest isn't available with Command Line Tools only).
var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    do { try body() } catch {
        failures += 1
        print("FAIL \(name): threw \(error)")
    }
}

let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("nosleep-selftest-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }

// MARK: Duration parsing

test("durations") {
    check(DurationParser.duration("90") == 5400, "bare number = minutes")
    check(DurationParser.duration("45m") == 2700, "45m")
    check(DurationParser.duration("2h") == 7200, "2h")
    check(DurationParser.duration("1h30m") == 5400, "1h30m")
    check(DurationParser.duration("1h30") == 5400, "1h30 → trailing minutes")
    check(DurationParser.duration("1.5h") == 5400, "1.5h")
    check(DurationParser.duration("2 hours 15 min") == 8100, "long units")
    check(DurationParser.duration("30s") == 30, "seconds")
    check(DurationParser.duration("abc") == nil, "garbage")
    check(DurationParser.duration("0") == nil, "zero")
    check(DurationParser.duration("") == nil, "empty")
}

test("clock times") {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15, minute: 0))!
    let later = DurationParser.endDate(for: "18:30", now: now, calendar: calendar)
    check(later == calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 18, minute: 30)), "18:30 today")
    let tomorrow = DurationParser.endDate(for: "9am", now: now, calendar: calendar)
    check(tomorrow == calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9)), "9am tomorrow")
    let pm = DurationParser.endDate(for: "6:15pm", now: now, calendar: calendar)
    check(pm == calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 18, minute: 15)), "6:15pm")
    check(DurationParser.endDate(for: "25:00", now: now, calendar: calendar) == nil, "invalid hour")
    check(DurationParser.endDate(for: "30m", now: now, calendar: calendar) == now.addingTimeInterval(1800), "duration path")
    check(DurationParser.countdown(3725) == "1:02:05", "countdown h")
    check(DurationParser.countdown(65) == "1:05", "countdown m")
}

// MARK: JSON

test("ordered json round trip") {
    let text = """
    {
      "z": 1,
      "a": [true, false, null, 1.50, -2e3],
      "s": "quote \\" slash / tab \\t é \\ud83d\\ude00",
      "empty": {},
      "list": []
    }
    """
    let value = try JSONValue.parse(text)
    let output = value.serialized()
    check(output.firstIndex(of: "z")! < output.firstIndex(of: "a")!, "key order preserved")
    check(output.contains("1.50"), "number literal preserved")
    check(output.contains("-2e3"), "exponent preserved")
    check(output.contains("😀"), "surrogate pair decoded")
    let reparsed = try JSONValue.parse(output); check(reparsed == value, "re-parse equal")
    check((try? JSONValue.parse("{\"a\":}")) == nil, "invalid rejected")
    check((try? JSONValue.parse("[1,2] x")) == nil, "trailing garbage rejected")
}

// MARK: Hook installer

test("hook installer preserves user config") {
    let home = tempRoot.appendingPathComponent("home")
    let claudeDir = home.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    let original = """
    {
      "model": "opus",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "~/.claude/bin/other pre", "timeout": 5 }
            ]
          }
        ]
      },
      "theme": "dark"
    }
    """
    try original.write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

    let installer = HookInstaller(agent: .claude, cliPath: "/Applications/NoSleep.app/Contents/Helpers/nosleep", home: home)
    check(installer.status() == .notInstalled, "starts uninstalled")
    try installer.install()
    check(installer.status() == .installed, "installed")
    try installer.install() // idempotent
    let installed = try JSONValue.parse(String(contentsOf: installer.configURL, encoding: .utf8))
    check(installed["hooks"]?["PreToolUse"]?.arrayValue?.count == 2, "one other + one ours (idempotent)")
    check(installed["hooks"]?["Stop"]?.arrayValue?.count == 1, "Stop hook")
    check(installed["model"]?.stringValue == "opus", "other keys kept")
    let serialized = installed.serialized()
    check(serialized.range(of: "\"model\"")!.lowerBound < serialized.range(of: "\"theme\"")!.lowerBound, "order kept")

    // A moved app is detected as outdated and repaired.
    let moved = HookInstaller(agent: .claude, cliPath: "/Users/x/Apps/No Sleep.app/Contents/Helpers/nosleep", home: home)
    check(moved.status() == .outdated, "outdated when path differs")
    check(moved.command.hasPrefix("'/Users/x/Apps/No Sleep.app"), "path with spaces is quoted")
    try moved.install()
    check(moved.status() == .installed, "repaired")
    check(installer.status() == .outdated, "old path now outdated")

    try moved.uninstall()
    check(moved.status() == .notInstalled, "uninstalled")
    let restored = try JSONValue.parse(String(contentsOf: installer.configURL, encoding: .utf8))
    let originalValue = try JSONValue.parse(original); check(restored == originalValue, "uninstall restores original content")
    check(FileManager.default.fileExists(atPath: installer.configURL.path + ".nosleep-backup"), "backup written")

    let codex = HookInstaller(agent: .codex, cliPath: "/x/nosleep", home: home)
    try codex.install()
    let codexJSON = try JSONValue.parse(String(contentsOf: codex.configURL, encoding: .utf8))
    check(codexJSON["hooks"]?["Interrupt"] != nil, "codex hooks.json created with Interrupt")
    try codex.uninstall()
    let codexText = try String(contentsOf: codex.configURL, encoding: .utf8); check(codexText.trimmingCharacters(in: .whitespacesAndNewlines) == "{}", "codex cleaned")
}

// MARK: Hook events

test("hook events") {
    let prompt = AgentHookEvent.parse(agent: .claude, json: Data(#"{"session_id":"abc","hook_event_name":"UserPromptSubmit","cwd":"/Users/me/proj"}"#.utf8))
    check(prompt?.action == .acquire, "prompt acquires")
    check(prompt?.leaseID(fallbackPID: 1) == "claude-abc", "lease id")
    check(prompt?.presentation(environment: [:]).detail == "proj", "project name")
    check(prompt?.presentation(environment: ["T3CODE_THREAD_ID": "x"]).label == "T3 Code · Claude Code", "T3 detection")
    let stop = AgentHookEvent.parse(agent: .codex, json: Data(#"{"session_id":"s","hook_event_name":"Stop"}"#.utf8))
    check(stop?.action == .release, "stop releases")
    let interrupt = AgentHookEvent.parse(agent: .codex, json: Data(#"{"session_id":"s","hook_event_name":"Interrupt"}"#.utf8))
    check(interrupt?.action == .release, "interrupt releases")
    let notify = AgentHookEvent.parse(agent: .codex, json: Data(#"{"type":"agent-turn-complete","thread-id":"t1"}"#.utf8))
    check(notify?.action == .release && notify?.sessionID == "t1", "codex notify payload")
    let start = AgentHookEvent.parse(agent: .claude, json: Data(#"{"hook_event_name":"SessionStart"}"#.utf8))
    check(start?.action == .ignore, "session start ignored")
    check(AgentHookEvent.parse(agent: .claude, json: Data("nope".utf8)) == nil, "garbage ignored")
}

// MARK: Leases

test("lease store") {
    let store = LeaseStore(directory: tempRoot.appendingPathComponent("leases"))
    let now = Date()
    let first = try store.upsert(id: "claude-abc", source: "claude", label: "Claude Code", ttl: 60, now: now)
    check(first.created, "new lease")
    let again = try store.upsert(id: "claude-abc", source: "claude", ttl: 60, now: now.addingTimeInterval(10))
    check(!again.created, "heartbeat keeps lease")
    check(abs(again.lease.createdAt.timeIntervalSince(now)) < 1, "createdAt kept")
    check(again.lease.label == "Claude Code", "label kept on heartbeat")

    try store.upsert(id: "../../evil id", source: "cli", now: now)
    check(store.lease(id: "../../evil id") != nil, "sanitized id round trips")
    check(!FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("evil id.json").path), "no path traversal")

    try store.upsert(id: "dead", source: "cli", pid: getpid(), now: now)
    check(store.pruneAndList(now: now, isProcessAlive: { _, _ in true }).count == 3, "all valid")
    let pruned = store.pruneAndList(now: now.addingTimeInterval(120), isProcessAlive: { _, _ in false })
    check(pruned.map(\.id) == [LeaseStore.sanitize(id: "../../evil id")], "expired + dead pruned: \(pruned.map(\.id))")
    check(store.all().count == 1, "pruned files deleted")
    check(store.remove(id: "../../evil id"), "remove")
    check(store.all().isEmpty, "empty")
}

test("process inspector") {
    let me = ProcessInspector.snapshot(of: getpid())
    check(me != nil, "can inspect self")
    check(ProcessInspector.isAlive(pid: getpid(), startTime: me?.startTime), "self alive")
    check(!ProcessInspector.isAlive(pid: getpid(), startTime: (me?.startTime ?? 0) - 1000), "pid reuse detected")
    check(!ProcessInspector.isAlive(pid: 999_999, startTime: nil), "missing pid")
}

// MARK: Thermal failsafe

test("thermal failsafe") {
    let t0 = Date()
    var failsafe = ThermalFailsafe()
    check(!failsafe.observe(level: .serious, isActive: true, now: t0), "starts counting")
    check(failsafe.hotSince == t0, "hotSince set")
    check(!failsafe.observe(level: .critical, isActive: true, now: t0.addingTimeInterval(19 * 60)), "19 min: not yet")
    check(failsafe.remaining(now: t0.addingTimeInterval(19 * 60)) == 60, "1 min remaining")
    check(failsafe.observe(level: .serious, isActive: true, now: t0.addingTimeInterval(20 * 60)), "20 min: trips")
    check(failsafe.hotSince == nil, "count restarts after tripping")

    var interrupted = ThermalFailsafe()
    _ = interrupted.observe(level: .serious, isActive: true, now: t0)
    _ = interrupted.observe(level: .fair, isActive: true, now: t0.addingTimeInterval(10 * 60))
    check(!interrupted.observe(level: .serious, isActive: true, now: t0.addingTimeInterval(25 * 60)), "cooling down resets the 20 min")

    var inactive = ThermalFailsafe()
    _ = inactive.observe(level: .critical, isActive: true, now: t0)
    _ = inactive.observe(level: .critical, isActive: false, now: t0.addingTimeInterval(5 * 60))
    check(!inactive.observe(level: .critical, isActive: true, now: t0.addingTimeInterval(21 * 60)), "only counts while keeping awake")

    check(!ThermalLevel.fair.isHot && ThermalLevel.serious.isHot && ThermalLevel.critical.isHot, "hot levels")
    check(ThermalLevel(ProcessInfo.ThermalState.critical) == .critical, "maps ProcessInfo state")
}

// MARK: Offline failsafe

test("sustained condition") {
    let t0 = Date()
    var offline = SustainedCondition(limit: 15 * 60)
    check(!offline.observe(true, now: t0), "starts counting")
    check(offline.remaining(now: t0.addingTimeInterval(60)) == 14 * 60, "14 min left")
    check(!offline.observe(true, now: t0.addingTimeInterval(14 * 60)), "14 min: not yet")
    check(offline.observe(true, now: t0.addingTimeInterval(15 * 60)), "15 min: fires")
    check(offline.since == nil, "restarts after firing")
    _ = offline.observe(true, now: t0)
    _ = offline.observe(false, now: t0.addingTimeInterval(5 * 60))
    check(!offline.observe(true, now: t0.addingTimeInterval(16 * 60)), "back online resets the window")

    check(Lease(id: "a", source: "claude").isAgent && Lease(id: "b", source: "codex").isAgent, "agent leases")
    check(!Lease(id: "c", source: "cli").isAgent, "cli lease is not an agent")
}

// MARK: Updates

test("versions") {
    check(AppVersion("1.10.0")! > AppVersion("1.9.3")!, "numeric, not lexical")
    check(AppVersion("v1.2.0")! == AppVersion("1.2")!, "v prefix + missing zeros")
    check(AppVersion("1.2.0-beta")! == AppVersion("1.2.0")!, "suffix ignored")
    check(AppVersion("1.1.4")! < AppVersion("1.2.0")!, "minor bump")
    check(AppVersion("abc") == nil && AppVersion("") == nil, "garbage")
}

test("asset picking") {
    func asset(_ name: String) -> GitHubRelease.Asset {
        GitHubRelease.Asset(name: name, browserDownloadURL: URL(string: "https://example.com/\(name)")!)
    }
    let assets = [
        asset("NoSleep-1.2.0-macos26-apple-silicon.dmg"),
        asset("NoSleep-1.2.0-macos27-apple-silicon.dmg"),
        asset("NoSleep-1.2.0-macos14-sonoma-apple-silicon.dmg"),
        asset("notes.txt"),
    ]
    check(UpdateAssetPicker.pick(assets, macOSMajor: 27, isAppleSilicon: true)?.name.contains("macos27") == true, "27 → 27")
    check(UpdateAssetPicker.pick(assets, macOSMajor: 26, isAppleSilicon: true)?.name.contains("macos26") == true, "26 → 26")
    check(UpdateAssetPicker.pick(assets, macOSMajor: 15, isAppleSilicon: true)?.name.contains("macos14") == true, "15 → 14")
    check(UpdateAssetPicker.pick(Array(assets.prefix(2)), macOSMajor: 14, isAppleSilicon: true) == nil, "nothing for 14")
    check(UpdateAssetPicker.pick(assets, macOSMajor: 27, isAppleSilicon: false) == nil, "no Intel build")
    check(UpdateAssetPicker.pick([asset("NoSleep-1.2.0-macos14-universal.dmg")], macOSMajor: 14, isAppleSilicon: false) != nil, "universal ok on Intel")

    let json = #"{"tag_name":"v1.2.0","name":"No Sleep 1.2.0","body":"hi","draft":false,"prerelease":false,"html_url":"https://github.com/pi-na/no-sleep/releases/tag/v1.2.0","assets":[{"name":"NoSleep-1.2.0-macos27-apple-silicon.dmg","browser_download_url":"https://github.com/x.dmg","size":10,"digest":"sha256:ABCD"}]}"#
    let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    check(release.version == AppVersion("1.2.0"), "release version")
    check(release.assets.first?.sha256 == "abcd", "digest parsed")
}

print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
