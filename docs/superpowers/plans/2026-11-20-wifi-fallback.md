# Wi‑Fi fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When internet is lost, No Sleep joins a user-chosen known network (typically an iPhone hotspot), first via `networksetup`, then by pressing the network in the Wi‑Fi menu through Accessibility (Instant Hotspot).

**Architecture:** Pure decision logic (`WiFiFallbackPolicy`) in NoSleepCore, tested by `nosleep-selftest`. Thin system wrappers in the app (`WiFi` for `networksetup`, `InstantHotspot` for AXUIElement). `WiFiFallback` (@Observable) owns prefs + state, runs attempts off the main thread, and is ticked by `SleepController.update()`. `Connectivity` learns to tell a captive portal apart and to probe while the fallback is on.

**Tech Stack:** Swift 5.10, SwiftUI/AppKit, ApplicationServices (AX), Network, `networksetup`.

**Spec:** `docs/superpowers/specs/2026-11-20-wifi-fallback-design.md`

## Global Constraints

- macOS 14 minimum; no private frameworks; no Location permission.
- Toggle off by default. Prefs keys: `wifiFallbackEnabled`, `wifiFallbackSSID`.
- Trigger after 30 s offline; captive portal never triggers; Wi‑Fi powered off never triggers.
- Max 3 cycles; waits between cycles 60 s then 180 s; then give up until online again, the network changes, or the toggle/SSID changes.
- Per cycle: join wait 20 s for internet; AX: find element ≤ 5 s, then wait ≤ 30 s for association, then ≤ 20 s for internet.
- Menu element id: `wifi-network-<SSID>`; Wi‑Fi menu bar extra: description starts with "Wi"; current network = checkbox `AXValue == 1`. Never press an already-checked entry.
- UI copy in English.

## Review Focus

- SSID with spaces/accents/parentheses ("iPhone de Tomás (2)") — passed as one argv element, matched exactly in AX ids.
- Fallback network itself has no internet (iPhone has no signal) — must not loop: counts as failed cycle, gives up after 3.
- User turns the toggle off mid-attempt — the attempt result is ignored and state returns to idle.
- Wi‑Fi menu already open (user had it open) — don't toggle it closed and fail; reuse the open window.
- Accessibility not granted — skip AX step without error spam; status says permission missing.

---

### Task 1: `WiFiFallbackPolicy` (NoSleepCore) + selftests

**Files:** Create `Sources/NoSleepCore/WiFiFallbackPolicy.swift`; Modify `Sources/NoSleepSelfTest/main.swift`

**Interfaces — Produces:**
```swift
public enum InternetState: Sendable { case online, offline, captivePortal }
public struct WiFiFallbackPolicy: Sendable {
    public static let offlineDelay: TimeInterval = 30
    public static let retryDelays: [TimeInterval] = [60, 180]
    public static let maxCycles = 3
    public enum Phase: Equatable, Sendable { case idle, attempting(cycle: Int), waiting(cycle: Int, until: Date), gaveUp }
    public private(set) var phase: Phase
    public init()
    /// Returns the cycle number (1-based) to start now, or nil.
    public mutating func observe(enabled: Bool, configured: Bool, wifiPowered: Bool, internet: InternetState, network: String?, now: Date) -> Int?
    public mutating func attemptFinished(success: Bool, now: Date)
    public mutating func reset()
}
```

- [ ] Tests (`test("wifi fallback policy")`): disabled/unconfigured → nil; offline 29 s → nil, 30 s → 1 and phase `.attempting(1)`; `.captivePortal` for 60 s → nil; `wifiPowered: false` → nil; while attempting → nil; failure → `.waiting(1, now+60)`, start 2 at +60; failure → wait 180, start 3; failure → `.gaveUp`, stays nil while offline; online → `.idle`; gave up then `network` changes → can trigger again after 30 s; success → idle; online during `.waiting` → idle.
- [ ] Run `swift build --product nosleep-selftest && .build/debug/nosleep-selftest` → FAIL (no type).
- [ ] Implement.
- [ ] Run → "All N checks passed."
- [ ] Commit.

### Task 2: Connectivity — captive portal + standalone probe

**Files:** Modify `Sources/NoSleepApp/System/Connectivity.swift`, `Sources/NoSleepApp/SleepController.swift`

**Produces:** `Connectivity.internet: InternetState` (observable); `static func probeOnce() async -> InternetState`; `setProbing` unchanged signature. Probe: 200 + "Success" → online; any other HTTP response → captivePortal; error/timeout → offline. Path unsatisfied → offline. `isOnline` stays `internet == .online` (failsafe unchanged). SleepController: `connectivity.setProbing(watching || wifiFallback.enabled)`.

- [ ] Implement; `swift build` passes; selftest still passes. Commit with Task 3–4 (no standalone deliverable).

### Task 3: System wrappers `WiFi` and `InstantHotspot`

**Files:** Create `Sources/NoSleepApp/System/WiFi.swift`, `Sources/NoSleepApp/System/InstantHotspot.swift`; Modify `Package.swift` (link `ApplicationServices` only if needed).

**Produces:**
```swift
enum WiFi {  // all blocking; call off main
    static func interface() -> String?            // "Wi-Fi" port from -listallhardwareports
    static func knownNetworks() -> [String]       // -listpreferredwirelessnetworks, trimmed
    static func isPoweredOn() -> Bool             // -getairportpower → ends with "On"
    static func currentNetwork() -> String?       // nil when hidden (macOS 15+) or not associated
    static func join(_ ssid: String) -> Bool      // -setairportnetwork, true if no output
}
enum InstantHotspot {
    static var isTrusted: Bool
    static func requestTrust()                     // prompt + open Privacy pane
    enum Outcome: Equatable { case pressed, alreadyConnected, notFound, menuUnavailable, notTrusted }
    static func press(_ ssid: String) -> Outcome   // blocking ≤ ~6 s
    static func connectedNetwork() -> String?      // opens menu, reads checked entry, closes
}
```
Process runner with 15 s timeout. AX: `com.apple.controlcenter` pid → `AXExtrasMenuBar` children → `AXDescription` hasPrefix "Wi" → reuse an open window or `AXPress`; poll windows' descendants every 0.5 s up to 5 s for `AXIdentifier`; press, or close menu (`AXPress` the extra again) when not found / already connected.

- [ ] Verify by a debug hook: `NoSleep --wifi-debug <ssid>` prints `knownNetworks`, `currentNetwork`, `connectedNetwork`, and `press("no-existe")` → `notFound`. Expected on this Mac: list contains "pina", connectedNetwork = current Wi‑Fi.

### Task 4: `WiFiFallback` controller + menu + settings + README

**Files:** Create `Sources/NoSleepApp/WiFiFallback.swift`; Modify `SleepController.swift`, `UI/MenuContentView.swift`, `UI/SettingsView.swift`, `README.md`

**Produces:**
```swift
@MainActor @Observable final class WiFiFallback {
    var enabled: Bool; var ssid: String?            // persisted
    private(set) var knownNetworks: [String]
    private(set) var status: Status                  // drives menu line
    private(set) var testResult: String?
    enum Status: Equatable { case off, needsNetwork, ready, connecting, connected(at: Date), retrying(at: Date), gaveUp }
    var needsPermission: Bool                        // !InstantHotspot.isTrusted
    func refreshKnownNetworks()
    func tick(internet: InternetState)               // called from SleepController.update()
    func testNow()
}
```
Cycle (detached task): `WiFi.join` → if `currentNetwork == ssid` wait online 20 s → success; else if trusted `InstantHotspot.press` (`.alreadyConnected` → wait online 20 s) → wait association 30 s (poll `currentNetwork`; if it's nil throughout, just wait online up to 50 s) → wait online 20 s. Result ignored if toggle/SSID changed meanwhile. `testNow`: same cycle regardless of internet; success = on ssid (via `currentNetwork ?? InstantHotspot.connectedNetwork()`) and online.

Menu: `WiFiFallbackSection` after Screen glow: title + switch, caption line: ready "If the internet drops, joins “X”"; connecting "Joining “X”…"; connected "Joined “X” at 7:02 PM"; retrying "Couldn't reach “X”. Retrying at …"; gaveUp "Couldn't reach “X”. Will try again when the network changes."; needsNetwork / needsPermission "Choose a network in Settings" / "Needs Accessibility permission" (tap → Settings).

Settings: section "Wi‑Fi fallback": toggle; Picker of known networks; Accessibility row (status + "Grant…" button); iPhone tips footer; "Test now" button + result.

- [ ] Build app `scripts/build-app.sh`, selftests pass.
- [ ] Manual: install, enable, pick "pina", Test now with lid open → joins "pina"; then lid-closed test.
- [ ] README bullet. Commit, push, PR, merge.
