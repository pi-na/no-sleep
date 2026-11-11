import AppKit
import Foundation
import NoSleepCore
import Observation
import notify

/// Single source of truth: decides whether the Mac should stay awake and applies it.
///
/// Reasons to stay awake (any of them):
///  - the manual toggle ("until you turn it off")
///  - a running timer
///  - external leases (agent hooks, `nosleep` CLI)
@MainActor
@Observable
final class SleepController {
    enum LidIssue: Equatable {
        case needsSetup
        case failed(String)
    }

    private enum Keys {
        static let manualEnabled = "manualEnabled"
        static let timerEnd = "timerEnd"
        static let externalTriggersEnabled = "externalTriggersEnabled"
        static let preventLidSleep = "preventLidSleep"
        static let keepDisplayAwake = "keepDisplayAwake"
        static let batteryGuardEnabled = "batteryGuardEnabled"
        static let batteryGuardThreshold = "batteryGuardThreshold"
        static let lidAppliedByUs = "lidAppliedByUs"
        static let thermalFailsafeEnabled = "thermalFailsafeEnabled"
    }

    // MARK: State

    private(set) var manualEnabled: Bool {
        didSet { defaults.set(manualEnabled, forKey: Keys.manualEnabled) }
    }

    private(set) var timerEnd: Date? {
        didSet { defaults.set(timerEnd, forKey: Keys.timerEnd); scheduleTimerFire() }
    }

    /// Valid leases on disk (before filtering dismissed ones).
    private(set) var leases: [Lease] = []

    /// Leases the user switched off; ignored until that lease goes away.
    private var dismissedLeaseIDs: Set<String> = []

    var externalTriggersEnabled: Bool {
        didSet { defaults.set(externalTriggersEnabled, forKey: Keys.externalTriggersEnabled); update() }
    }

    var preventLidSleep: Bool {
        didSet { defaults.set(preventLidSleep, forKey: Keys.preventLidSleep); lidSetupPrompted = false; update(userInitiated: preventLidSleep) }
    }

    var keepDisplayAwake: Bool {
        didSet { defaults.set(keepDisplayAwake, forKey: Keys.keepDisplayAwake); update() }
    }

    var batteryGuardEnabled: Bool {
        didSet { defaults.set(batteryGuardEnabled, forKey: Keys.batteryGuardEnabled); update() }
    }

    var batteryGuardThreshold: Int {
        didSet { defaults.set(batteryGuardThreshold, forKey: Keys.batteryGuardThreshold); update() }
    }

    /// Turns No Sleep off if the Mac stays hot for `ThermalFailsafe.defaultLimit` while kept awake.
    var thermalFailsafeEnabled: Bool {
        didSet {
            defaults.set(thermalFailsafeEnabled, forKey: Keys.thermalFailsafeEnabled)
            if !thermalFailsafeEnabled {
                thermalFailsafe.reset()
                thermalLockout = false
                thermalTrippedAt = nil
            }
            update()
        }
    }

    var agentIdleTimeoutMinutes: Int {
        didSet { defaults.set(agentIdleTimeoutMinutes, forKey: NoSleepConstants.agentIdleTimeoutKey) }
    }

    private(set) var battery: BatteryState?
    private(set) var lidHelperInstalled = LidSleepControl.isHelperInstalled
    private(set) var lidSleepApplied = false
    private(set) var lidIssue: LidIssue?
    private(set) var isSettingUpLidHelper = false

    private(set) var thermalLevel = ThermalLevel(ProcessInfo.processInfo.thermalState)
    private(set) var thermalFailsafe = ThermalFailsafe()
    /// When the failsafe last turned No Sleep off (shown in the menu until the user acts).
    private(set) var thermalTrippedAt: Date?
    /// After tripping, agents can't turn No Sleep back on until the Mac cools down.
    private(set) var thermalLockout = false
    /// Snapshot/debug only: pretend to be at this thermal level.
    var thermalOverride: ThermalLevel?

    // MARK: Derived

    var timerActive: Bool { (timerEnd ?? .distantPast) > Date() }

    var activeLeases: [Lease] {
        guard externalTriggersEnabled, !thermalLockout else { return [] }
        return leases.filter { !dismissedLeaseIDs.contains($0.id) }
    }

    /// What the user asked for (drives the toggle).
    var wantsAwake: Bool { manualEnabled || timerActive || !activeLeases.isEmpty }

    var pausedForBattery: Bool {
        guard wantsAwake, batteryGuardEnabled, let battery, battery.onBattery else { return false }
        return battery.percentage <= batteryGuardThreshold
    }

    /// What is actually applied (drives the menu bar icon).
    var isActive: Bool { wantsAwake && !pausedForBattery }

    /// Lid-closed protection is in effect right now.
    var coversLidClose: Bool { isActive && preventLidSleep && lidSleepApplied }

    // MARK: Private

    private let defaults = UserDefaults.standard
    private let leaseStore = LeaseStore()
    private let idleAssertion = PowerAssertion(.preventIdleSystemSleep, reason: "No Sleep is keeping this Mac awake")
    private let displayAssertion = PowerAssertion(.preventIdleDisplaySleep, reason: "No Sleep is keeping the display on")
    /// Serialises pmset calls so they apply in order.
    private let lidQueue = DispatchQueue(label: "com.tomaspinausig.nosleep.lid")
    private var lidRequested: Bool?
    private var lidSetupPrompted = false
    /// Compute state only, never touch power settings (used for UI snapshots).
    var dryRun = false
    private var pollTimer: Timer?
    private var endTimer: Timer?
    private var notifyToken: Int32 = 0

    init() {
        defaults.register(defaults: [
            Keys.externalTriggersEnabled: true,
            Keys.preventLidSleep: true,
            Keys.keepDisplayAwake: false,
            Keys.batteryGuardEnabled: true,
            Keys.batteryGuardThreshold: 10,
            Keys.thermalFailsafeEnabled: true,
            NoSleepConstants.agentIdleTimeoutKey: NoSleepConstants.defaultAgentIdleTimeoutMinutes,
        ])
        manualEnabled = defaults.bool(forKey: Keys.manualEnabled)
        timerEnd = (defaults.object(forKey: Keys.timerEnd) as? Date).flatMap { $0 > Date() ? $0 : nil }
        externalTriggersEnabled = defaults.bool(forKey: Keys.externalTriggersEnabled)
        preventLidSleep = defaults.bool(forKey: Keys.preventLidSleep)
        keepDisplayAwake = defaults.bool(forKey: Keys.keepDisplayAwake)
        batteryGuardEnabled = defaults.bool(forKey: Keys.batteryGuardEnabled)
        batteryGuardThreshold = defaults.integer(forKey: Keys.batteryGuardThreshold)
        agentIdleTimeoutMinutes = defaults.integer(forKey: NoSleepConstants.agentIdleTimeoutKey)
        thermalFailsafeEnabled = defaults.bool(forKey: Keys.thermalFailsafeEnabled)

        // If we left `disablesleep 1` behind (crash, logout…), treat it as currently applied so the
        // first update() either keeps it (still wanted) or restores normal sleep.
        if defaults.bool(forKey: Keys.lidAppliedByUs) {
            let stillDisabled = LidSleepControl.isSleepDisabled() ?? true
            lidSleepApplied = stillDisabled
            lidRequested = stillDisabled
            if !stillDisabled { defaults.set(false, forKey: Keys.lidAppliedByUs) }
        }
    }

    func start() {
        scheduleTimerFire()
        refresh()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pollTimer?.tolerance = 2

        notify_register_dispatch(NoSleepConstants.leasesChangedNotification, &notifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: User actions

    func setEnabled(_ enabled: Bool) {
        clearThermalTrip()
        timerEnd = nil
        manualEnabled = enabled
        if !enabled {
            // "Off" means off now: ignore agents currently holding leases until they finish.
            dismissedLeaseIDs.formUnion(leases.map(\.id))
        }
        update(userInitiated: enabled)
    }

    func startTimer(until end: Date) {
        guard end > Date() else { return }
        clearThermalTrip()
        manualEnabled = false
        timerEnd = end
        update(userInitiated: true)
    }

    func startTimer(duration: TimeInterval) {
        startTimer(until: Date().addingTimeInterval(duration))
    }

    func cancelTimer() {
        timerEnd = nil
        update()
    }

    func dismiss(_ lease: Lease) {
        dismissedLeaseIDs.insert(lease.id)
        if lease.source == "cli" { leaseStore.remove(id: lease.id) }
        update()
    }

    // MARK: Refresh / apply

    func refresh() {
        leases = leaseStore.pruneAndList()
        dismissedLeaseIDs.formIntersection(leases.map(\.id))
        battery = BatteryState.current()
        lidHelperInstalled = LidSleepControl.isHelperInstalled
        thermalLevel = thermalOverride ?? ThermalLevel(ProcessInfo.processInfo.thermalState)
        update()
    }

    /// An explicit user action overrides a previous failsafe trip.
    private func clearThermalTrip() {
        thermalTrippedAt = nil
        thermalLockout = false
        thermalFailsafe.reset()
    }

    /// Debug/snapshot helper: show lid-closed protection as applied.
    func simulateLidApplied() {
        guard dryRun else { return }
        lidSleepApplied = true
    }

    /// Debug/snapshot helper.
    func simulateThermal(level: ThermalLevel, hotFor: TimeInterval) {
        thermalOverride = level
        thermalLevel = level
        thermalFailsafe = ThermalFailsafe(hotSince: Date().addingTimeInterval(-hotFor))
    }

    private func checkThermalFailsafe() {
        if thermalLockout, !thermalLevel.isHot { thermalLockout = false }
        guard thermalFailsafeEnabled else { return }
        guard thermalFailsafe.observe(level: thermalLevel, isActive: isActive) else { return }
        // Too hot for too long: switch everything off, like the user flipping the toggle.
        thermalTrippedAt = Date()
        thermalLockout = true
        timerEnd = nil
        manualEnabled = false
        dismissedLeaseIDs.formUnion(leases.map(\.id))
    }

    /// - Parameter userInitiated: only a direct user action may pop up the one-time admin prompt;
    ///   agents and timers firing in the background never do.
    private func update(userInitiated: Bool = false) {
        if let end = timerEnd, end <= Date() { timerEnd = nil }
        checkThermalFailsafe()
        if dryRun { return }
        let active = isActive
        idleAssertion.set(active)
        displayAssertion.set(active && keepDisplayAwake)
        applyLid(active && preventLidSleep, mayPrompt: userInitiated)
    }

    private func applyLid(_ wanted: Bool, mayPrompt: Bool) {
        if !wanted, lidIssue == .needsSetup { lidIssue = nil }
        guard wanted != lidRequested else { return }

        if wanted, !LidSleepControl.isHelperInstalled {
            lidIssue = .needsSetup
            if mayPrompt, !lidSetupPrompted {
                lidSetupPrompted = true
                setUpLidHelper()
            }
            return
        }

        lidRequested = wanted
        lidQueue.async {
            let ok = LidSleepControl.setSleepDisabled(wanted)
            DispatchQueue.main.async { [weak self] in
                self?.lidCallFinished(wanted: wanted, ok: ok)
            }
        }
    }

    private func lidCallFinished(wanted: Bool, ok: Bool) {
        if ok {
            lidSleepApplied = wanted
            defaults.set(wanted, forKey: Keys.lidAppliedByUs)
            if lidRequested == wanted { lidIssue = nil }
        } else if lidRequested == wanted {
            lidRequested = nil
            lidHelperInstalled = LidSleepControl.isHelperInstalled
            lidIssue = lidHelperInstalled
                ? .failed("Couldn't change the sleep setting (pmset failed).")
                : .needsSetup
        }
    }

    /// Asks for admin rights once and installs the sudoers rule for `pmset disablesleep`.
    func setUpLidHelper() {
        guard !isSettingUpLidHelper else { return }
        isSettingUpLidHelper = true
        let applyNow: Bool? = isActive && preventLidSleep ? true : nil
        lidQueue.async {
            let failure: Error?
            do { try LidSleepControl.installHelper(apply: applyNow); failure = nil } catch { failure = error }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSettingUpLidHelper = false
                self.lidHelperInstalled = LidSleepControl.isHelperInstalled
                switch failure {
                case nil:
                    self.lidIssue = nil
                    if applyNow == true {
                        self.lidSleepApplied = true
                        self.lidRequested = true
                        self.defaults.set(true, forKey: Keys.lidAppliedByUs)
                    }
                    self.update()
                case LidSleepControl.SetupError.cancelled?:
                    self.lidIssue = .needsSetup
                case let error?:
                    self.lidIssue = .failed(error.localizedDescription)
                }
            }
        }
    }

    func removeLidHelper() {
        lidQueue.async {
            let error: Error?
            do { try LidSleepControl.uninstallHelper(); error = nil } catch let caught { error = caught }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if error == nil {
                    self.lidSleepApplied = false
                    self.lidRequested = false
                    self.defaults.set(false, forKey: Keys.lidAppliedByUs)
                }
                self.lidSetupPrompted = true // don't immediately prompt again
                self.refresh()
            }
        }
    }

    private func scheduleTimerFire() {
        endTimer?.invalidate()
        endTimer = nil
        guard let end = timerEnd, end > Date() else { return }
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    // MARK: Termination

    /// Restores normal sleep before the app exits.
    /// - Parameter forget: true when the user explicitly quits (don't resume on next launch).
    func shutdown(forget: Bool) {
        if forget {
            manualEnabled = false
            timerEnd = nil
        }
        idleAssertion.set(false)
        displayAssertion.set(false)
        if lidSleepApplied || defaults.bool(forKey: Keys.lidAppliedByUs) {
            let ok = lidQueue.sync { LidSleepControl.setSleepDisabled(false) }
            if ok {
                lidSleepApplied = false
                defaults.set(false, forKey: Keys.lidAppliedByUs)
            }
        }
        defaults.synchronize()
    }
}
