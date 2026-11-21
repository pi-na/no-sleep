import AppKit
import NoSleepCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var controller: SleepController
    let integrations: Integrations
    let updater: Updater
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            generalSection
            glowSection
            wifiFallbackSection
            failsafeSection
            lidSection
            integrationsSection
            cliSection
            updatesSection
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 560)
        .onAppear {
            integrations.refresh()
            controller.refresh()
            controller.wifiFallback.refreshKnownNetworks()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            Toggle("Open at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    do {
                        try LoginItem.setEnabled(newValue)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    launchAtLogin = LoginItem.isEnabled
                }
            ))
            if let loginError {
                LabeledContent {
                    Button("Open Login Items…") { LoginItem.openSystemSettings() }
                } label: {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            }
            Toggle("Keep the display on too", isOn: $controller.keepDisplayAwake)
            Toggle(isOn: $controller.batteryGuardEnabled) {
                Text("Allow sleep when the battery is low")
                Text("Protects a closed MacBook in your bag from draining completely.")
            }
            if controller.batteryGuardEnabled {
                Picker("Battery threshold", selection: $controller.batteryGuardThreshold) {
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text(verbatim: "\($0)%").tag($0) }
                }
            }
        } header: {
            Text("General")
        }
    }

    // MARK: Screen glow

    private var glowSection: some View {
        Section {
            Toggle(isOn: $controller.glowEnabled) {
                Text("Glow at the bottom of the screen")
                Text("A faint band of color along the bottom edge of every display while your Mac is being kept awake.")
            }
            if controller.glowEnabled {
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        if controller.glowColorHex != SleepController.defaultGlowColorHex {
                            Button("Reset to Amber") { controller.glowColorHex = SleepController.defaultGlowColorHex }
                        }
                        ColorPicker("Color", selection: Binding(
                            get: { Color(nsColor: controller.glowColor) },
                            set: { controller.glowColor = NSColor($0) }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
                LabeledContent("Opacity") {
                    HStack(spacing: 8) {
                        Slider(value: $controller.glowOpacity, in: 0.05...1)
                            .frame(width: 180)
                        Text(verbatim: "\(Int((controller.glowOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                GlowPreview(color: controller.glowColor, opacity: controller.glowOpacity)
            }
        } header: {
            Text("Screen glow")
        }
    }

    // MARK: Wi‑Fi fallback

    private var wifiFallbackSection: some View {
        @Bindable var fallback = controller.wifiFallback
        return Section {
            Toggle(isOn: $fallback.enabled) {
                Text("Join a backup network when the internet drops")
                Text("After 30 seconds without internet, No Sleep joins the network you pick here. Made for your iPhone's hotspot: it reaches it even with the iPhone locked in your pocket and your Mac's lid closed. It tries 3 times, then waits for the network to change.")
            }
            Picker("Backup network", selection: $fallback.ssid) {
                Text("None").tag(String?.none)
                if let ssid = fallback.ssid, !fallback.knownNetworks.contains(ssid) {
                    Text(ssid).tag(String?.some(ssid))
                }
                ForEach(fallback.knownNetworks, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            LabeledContent("Accessibility permission") {
                HStack(spacing: 8) {
                    if fallback.accessibilityTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Not granted").foregroundStyle(.secondary)
                        Button("Grant…") { fallback.requestAccessibility() }
                    }
                }
            }
            LabeledContent {
                Button(fallback.isTesting ? LocalizedStringKey("Testing…") : LocalizedStringKey("Test now")) { fallback.testNow() }
                    .disabled(fallback.ssid == nil || fallback.isTesting)
            } label: {
                Text("Try it")
                Text(fallback.testResult ?? String(localized: "Joins the backup network now, even if the internet is up, and stays on it."))
            }
        } header: {
            Text("Wi‑Fi fallback")
        } footer: {
            Text("Accessibility lets No Sleep pick your iPhone from the Wi‑Fi menu, which wakes its hotspot even while it's locked (Instant Hotspot). For that, use the same Apple Account on both, with Bluetooth and Wi‑Fi on. On the iPhone, under Personal Hotspot, turn on **Maximize Compatibility** (2.4 GHz connects more reliably) and **Allow Others to Join**. It only acts while your Mac is awake, so pair it with No Sleep to keep working with the lid closed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Lid

    private var lidSection: some View {
        Section {
            Toggle(isOn: $controller.preventLidSleep) {
                Text("Stay awake with the lid closed")
                Text("Uses `pmset -a disablesleep`, like `sudo pmset disablesleep 1`.")
            }
            LabeledContent("Admin permission") {
                HStack(spacing: 8) {
                    if controller.lidHelperInstalled {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Revoke…") { controller.removeLidHelper() }
                    } else {
                        Text("Not granted").foregroundStyle(.secondary)
                        Button(controller.isSettingUpLidHelper ? LocalizedStringKey("Waiting…") : LocalizedStringKey("Grant…")) {
                            controller.setUpLidHelper()
                        }
                        .disabled(controller.isSettingUpLidHelper)
                    }
                }
            }
            if case .failed(let message)? = controller.lidIssue {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Lid closed")
        } footer: {
            Text("Granting adds a rule in /etc/sudoers.d/nosleep that only allows `pmset -a disablesleep 0` and `1` without a password. You're asked once; quitting No Sleep always restores normal sleep.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Failsafes

    private var failsafeSection: some View {
        Section {
            Toggle(isOn: $controller.thermalFailsafeEnabled) {
                Text("Thermal failsafe")
                Text("Turns No Sleep off if your Mac stays hot (serious or critical thermal state, as reported by macOS) for 20 minutes in a row while it's being kept awake. Agents can't turn it back on until it cools down.")
            }
            LabeledContent("Temperature now") {
                Label(controller.thermalLevel.localizedName,
                      systemImage: controller.thermalLevel.isHot ? "thermometer.high" : "thermometer.medium")
                    .foregroundStyle(controller.thermalLevel.isHot ? Color.orange : Color.secondary)
            }

            Toggle(isOn: $controller.offlineFailsafeEnabled) {
                Text("Offline failsafe")
                Text("If Claude Code, Codex or T3 Code agents are keeping your Mac awake but the internet is down, let it sleep. Your own toggle and timers aren't affected.")
            }
            if controller.offlineFailsafeEnabled {
                Picker("Internet down for", selection: $controller.offlineFailsafeMinutes) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
            LabeledContent("Internet now") {
                Label(controller.connectivity.isOnline ? LocalizedStringKey("Online") : LocalizedStringKey("Offline"),
                      systemImage: controller.connectivity.isOnline ? "wifi" : "wifi.slash")
                    .foregroundStyle(controller.connectivity.isOnline ? Color.secondary : Color.orange)
            }
        } header: {
            Text("Failsafes")
        } footer: {
            Text("When a failsafe kicks in with the lid closed, your Mac goes to sleep right away.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Integrations

    private var integrationsSection: some View {
        Section {
            Toggle(isOn: $controller.externalTriggersEnabled) {
                Text("Allow external triggers")
                Text("Lets Claude Code, Codex, T3 Code and the `nosleep` CLI keep your Mac awake. The menu's switch only ignores the tasks running now.")
            }
            LabeledContent {
                if integrations.allAgentsInstalled {
                    HStack(spacing: 8) {
                        Label("All connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Disconnect All") { integrations.disconnectAll() }
                    }
                } else {
                    Button("Connect All") { integrations.connectAll() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            } label: {
                Text("Hook up your agents")
                Text("Connects Claude Code and Codex in one go, which covers T3 Code threads too. Same as `nosleep connect all`.")
            }
            AgentRow(
                name: "Claude Code",
                systemImage: "sparkle",
                configPath: "~/.claude/settings.json",
                status: integrations.claudeStatus,
                available: integrations.claudeInstalledOnSystem,
                install: { integrations.install(.claude) },
                uninstall: { integrations.uninstall(.claude) },
                reveal: { integrations.reveal(.claude) }
            )
            AgentRow(
                name: "Codex",
                systemImage: "chevron.left.forwardslash.chevron.right",
                configPath: "~/.codex/hooks.json",
                status: integrations.codexStatus,
                available: integrations.codexInstalledOnSystem,
                note: String(localized: "Codex asks you to review new hooks the next time it starts."),
                install: { integrations.install(.codex) },
                uninstall: { integrations.uninstall(.codex) },
                reveal: { integrations.reveal(.codex) }
            )
            LabeledContent {
                if integrations.anyAgentInstalled {
                    Label("Covered", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Connect Claude Code or Codex").foregroundStyle(.secondary)
                }
            } label: {
                Label {
                    Text("T3 Code")
                    Text("T3 threads run Claude Code and Codex, so their hooks cover them.")
                } icon: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
            }
            Picker(selection: $controller.agentIdleTimeoutMinutes) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("2 hours").tag(120)
                Text("4 hours").tag(240)
            } label: {
                Text("Give up on a silent agent after")
                Text("Safety net in case an agent crashes without saying it stopped.")
            }
            if let error = integrations.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Agent integrations")
        } footer: {
            Text("While an agent is working, its hooks hold a lease that keeps your Mac awake. The lease is released when the turn ends, it's interrupted, or the agent's process exits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Updates

    @ViewBuilder
    private var updatesSection: some View {
        @Bindable var updater = updater
        Section {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            Toggle(isOn: $updater.automaticallyInstalls) {
                Text("Install updates automatically")
                Text("No Sleep restarts itself in a second and picks up where it left off.")
            }
            .disabled(!updater.automaticallyChecks)
            LabeledContent {
                HStack(spacing: 8) {
                    updateStatus
                    if case .available = updater.state {
                        Button("Install Now", action: updater.installNow)
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    } else {
                        Button("Check Now", action: updater.checkNow)
                            .disabled(updater.isBusy)
                    }
                }
            } label: {
                Text(verbatim: "No Sleep \(updater.currentVersion)")
                if let checked = updater.lastChecked {
                    Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from GitHub Releases and are installed only if they're signed by the same developer as this copy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
            Text(updater.state == .checking ? LocalizedStringKey("Checking…")
                  : updater.state == .downloading ? LocalizedStringKey("Downloading…") : LocalizedStringKey("Installing…"))
                .foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let version):
            Text("\(version) is available").foregroundStyle(.secondary)
        case .unsupported(let version):
            Text("\(version) is out, no download for this Mac yet").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        }
    }

    // MARK: CLI

    private var cliSection: some View {
        Section {
            LabeledContent {
                if integrations.cliLinked {
                    HStack {
                        Text(verbatim: "~/.local/bin/nosleep").foregroundStyle(.secondary)
                        Button("Remove") { integrations.unlinkCLI() }
                    }
                } else {
                    Button("Install in ~/.local/bin") { integrations.linkCLI() }
                }
            } label: {
                Text(verbatim: "nosleep")
            }
            VStack(alignment: .leading, spacing: 4) {
                ExampleCommand("nosleep run -- make release", "stay awake while a command runs")
                ExampleCommand("nosleep for 1h30m", "stay awake for a while")
                ExampleCommand("nosleep acquire backup --pid 1234", "until a process exits")
            }
            .padding(.vertical, 2)
        } header: {
            Text("Command line")
        }
    }
}

@MainActor
private struct AgentRow: View {
    let name: String
    let systemImage: String
    let configPath: String
    let status: HookInstaller.Status
    let available: Bool
    var note: String?
    let install: () -> Void
    let uninstall: () -> Void
    let reveal: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch status {
                case .installed:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Menu {
                        Button("Show \(configPath) in Finder", action: reveal)
                        Divider()
                        Button("Disconnect", role: .destructive, action: uninstall)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                case .outdated:
                    Button("Repair", action: install)
                    Button("Disconnect", action: uninstall)
                case .notInstalled:
                    Button("Connect", action: install)
                }
            }
        } label: {
            Label {
                Text(name)
                Text(subtitle)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }

    private var subtitle: String {
        switch status {
        case .installed:
            let hooks = String(localized: "Hooks in \(configPath).")
            return note.map { "\(hooks) \($0)" } ?? hooks
        case .outdated: return String(localized: "Hooks point to an old copy of No Sleep.")
        case .notInstalled:
            return available ? String(localized: "Adds hooks to \(configPath).")
                             : String(localized: "Not found on this Mac — you can still connect it.")
        }
    }
}

@MainActor
private struct ExampleCommand: View {
    let command: String
    let explanation: LocalizedStringKey
    init(_ command: String, _ explanation: LocalizedStringKey) {
        self.command = command
        self.explanation = explanation
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Text(explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// Hosts the settings form in a regular AppKit window (reliable for a menu-bar-only app).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(controller: SleepController, integrations: Integrations, updater: Updater) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller, integrations: integrations, updater: updater))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "No Sleep Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("NoSleepSettings")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the glow looks like at the bottom of a screen, so it can be tuned while the Mac isn't awake.
private struct GlowPreview: View {
    let color: NSColor
    let opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: Color(nsColor: color).opacity(opacity), location: 0),
                        .init(color: Color(nsColor: color).opacity(opacity * 0.4), location: 0.35),
                        .init(color: Color(nsColor: color).opacity(0), location: 1),
                    ],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(height: AwakeGlow.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .frame(height: 64)
            .accessibilityLabel("Glow preview")
    }
}
