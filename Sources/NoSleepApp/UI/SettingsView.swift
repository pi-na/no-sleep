import AppKit
import NoSleepCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var controller: SleepController
    let integrations: Integrations
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            generalSection
            failsafeSection
            lidSection
            integrationsSection
            cliSection
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 560)
        .onAppear {
            integrations.refresh()
            controller.refresh()
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
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
        } header: {
            Text("General")
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
                        Button(controller.isSettingUpLidHelper ? "Waiting…" : "Grant…") {
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
                Label(controller.thermalLevel.displayName,
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
                Label(controller.connectivity.isOnline ? "Online" : "Offline",
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
                note: "Codex asks you to review new hooks the next time it starts.",
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

    // MARK: CLI

    private var cliSection: some View {
        Section {
            LabeledContent("nosleep") {
                if integrations.cliLinked {
                    HStack {
                        Text("~/.local/bin/nosleep").foregroundStyle(.secondary)
                        Button("Remove") { integrations.unlinkCLI() }
                    }
                } else {
                    Button("Install in ~/.local/bin") { integrations.linkCLI() }
                }
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
        case .installed: return note.map { "Hooks in \(configPath). \($0)" } ?? "Hooks in \(configPath)."
        case .outdated: return "Hooks point to an old copy of No Sleep."
        case .notInstalled:
            return available ? "Adds hooks to \(configPath)." : "Not found on this Mac — you can still connect it."
        }
    }
}

@MainActor
private struct ExampleCommand: View {
    let command: String
    let explanation: String
    init(_ command: String, _ explanation: String) {
        self.command = command
        self.explanation = explanation
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(command)
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

    func show(controller: SleepController, integrations: Integrations) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller, integrations: integrations))
            let window = NSWindow(contentViewController: hosting)
            window.title = "No Sleep Settings"
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
