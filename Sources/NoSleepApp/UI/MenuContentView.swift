import AppKit
import NoSleepCore
import SwiftUI

/// Content of the menu bar panel (`MenuBarExtra` with `.window` style).
@MainActor
struct MenuContentView: View {
    @Bindable var controller: SleepController
    let integrations: Integrations
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderSection(controller: controller)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if controller.wantsAwake || controller.lidIssue != nil {
                StatusSection(controller: controller)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            MenuDivider()
            TimerSection(controller: controller)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            MenuDivider()
            ExternalSection(controller: controller, integrations: integrations, openSettings: openSettings)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            MenuDivider()
            ThermalSection(controller: controller)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            MenuDivider()
            VStack(spacing: 0) {
                MenuActionRow(title: "Settings…", shortcut: "⌘,", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                MenuActionRow(title: "Quit No Sleep", shortcut: "⌘Q") {
                    (NSApp.delegate as? AppDelegate)?.quitFromMenu()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(5)
        }
        .frame(width: 320)
    }
}

// MARK: - Header

@MainActor
private struct HeaderSection: View {
    @Bindable var controller: SleepController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                (Text("No Sleep ") + Text(controller.wantsAwake ? "ENABLED" : "DISABLED")
                    .foregroundColor(controller.wantsAwake ? .red : .secondary).fontWeight(.heavy))
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("No Sleep", isOn: Binding(
                get: { controller.wantsAwake },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Prevent sleep")
        }
    }

    private var subtitle: String {
        if !controller.wantsAwake {
            return "Your Mac sleeps normally when closed or idle."
        }
        if controller.pausedForBattery {
            return "Paused while the battery is low. Your Mac can sleep."
        }
        if controller.coversLidClose {
            return "Mac will not go to sleep when closed or idle."
        }
        return "Mac will not go to sleep when idle. Closing the lid still puts it to sleep."
    }
}

// MARK: - Status

@MainActor
private struct StatusSection: View {
    let controller: SleepController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.wantsAwake {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    reasonRow(now: context.date)
                }
            }
            if controller.pausedForBattery, let battery = controller.battery {
                StatusRow(systemImage: "battery.25", tint: .orange,
                          text: "Battery at \(battery.percentage)% — sleep allowed")
            }
            if let issue = controller.lidIssue, controller.preventLidSleep {
                lidIssueRow(issue)
            }
        }
    }

    @ViewBuilder
    private func reasonRow(now: Date) -> some View {
        if let end = controller.timerEnd, end > now {
            HStack(spacing: 6) {
                StatusRow(
                    systemImage: "timer", tint: .red,
                    text: "Turns off in \(DurationParser.countdown(end.timeIntervalSince(now)))",
                    trailing: "at \(end.formatted(date: .omitted, time: .shortened))"
                )
                Button {
                    controller.cancelTimer()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Cancel timer")
            }
        } else if controller.manualEnabled {
            StatusRow(systemImage: "infinity", tint: .red, text: "Until you turn it off")
        } else if !controller.activeLeases.isEmpty {
            let count = controller.activeLeases.count
            StatusRow(systemImage: "bolt.fill", tint: .red,
                      text: count == 1 ? "While \(controller.activeLeases[0].displayTitle) is working"
                                       : "While \(count) external tasks are running")
        }
    }

    @ViewBuilder
    private func lidIssueRow(_ issue: SleepController.LidIssue) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                switch issue {
                case .needsSetup:
                    Text("Lid-closed protection needs a one-time admin approval.")
                case .failed(let message):
                    Text(message)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(controller.isSettingUpLidHelper ? "Waiting…" : "Set Up…") {
                controller.setUpLidHelper()
            }
            .controlSize(.small)
            .disabled(controller.isSettingUpLidHelper)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

@MainActor
private struct StatusRow: View {
    let systemImage: String
    let tint: Color
    let text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12).monospacedDigit())
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Timer

@MainActor
private struct TimerSection: View {
    let controller: SleepController
    @State private var customText = ""
    @FocusState private var customFocused: Bool

    private static let presets: [(String, TimeInterval)] = [
        ("15m", 15 * 60), ("30m", 30 * 60), ("1h", 3600), ("2h", 2 * 3600), ("4h", 4 * 3600), ("8h", 8 * 3600),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Timer")
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.0) { preset in
                    Button {
                        controller.startTimer(duration: preset.1)
                    } label: {
                        Text(preset.0).frame(maxWidth: .infinity)
                    }
                    .help("Keep awake for \(DurationParser.shortLabel(preset.1))")
                }
            }
            .controlSize(.small)

            HStack(spacing: 6) {
                TextField("Custom: 45m, 1h30m, 18:30…", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($customFocused)
                    .onSubmit(startCustom)
                if let end = parsedEnd {
                    Text("until \(end.formatted(date: Calendar.current.isDateInToday(end) ? .omitted : .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Button("Start", action: startCustom)
                    .controlSize(.small)
                    .disabled(parsedEnd == nil)
            }
        }
    }

    private var parsedEnd: Date? { DurationParser.endDate(for: customText) }

    private func startCustom() {
        guard let end = parsedEnd else { return }
        controller.startTimer(until: end)
        customText = ""
        customFocused = false
    }
}

// MARK: - External triggers

@MainActor
private struct ExternalSection: View {
    @Bindable var controller: SleepController
    let integrations: Integrations
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("External triggers")
                Spacer()
                Toggle("External triggers", isOn: $controller.externalTriggersEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Let Claude Code, Codex, T3 Code and the nosleep CLI keep your Mac awake")
            }

            if !controller.externalTriggersEnabled {
                Text("Agents and scripts can't keep your Mac awake.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if controller.leases.isEmpty {
                emptyState
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 2) {
                        ForEach(controller.leases) { lease in
                            LeaseRow(
                                lease: lease,
                                dismissed: !controller.activeLeases.contains(lease),
                                now: context.date,
                                dismiss: { controller.dismiss(lease) }
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if integrations.anyAgentInstalled {
            Text("Nothing running. Your Mac stays awake automatically while Claude Code, Codex or T3 Code threads are working.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .center, spacing: 8) {
                Text("Keep your Mac awake while Claude Code, Codex or T3 Code threads are working.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Connect…", action: openSettings)
                    .controlSize(.small)
            }
        }
    }
}

@MainActor
private struct LeaseRow: View {
    let lease: Lease
    let dismissed: Bool
    let now: Date
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(dismissed ? Color.secondary : Color.red)
                .frame(width: 22, height: 22)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(lease.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !dismissed {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.0)
                .help("Ignore until this task finishes")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(dismissed ? 0.55 : 1)
    }

    private var symbol: String {
        if lease.displayTitle.hasPrefix("T3 Code") { return "bubble.left.and.text.bubble.right" }
        switch lease.source {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "terminal"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let detail = lease.detail { parts.append(detail) }
        if dismissed {
            parts.append("ignored")
        } else {
            let minutes = Int(now.timeIntervalSince(lease.createdAt) / 60)
            parts.append(minutes < 1 ? "just started" : "for \(DurationParser.shortLabel(TimeInterval(minutes * 60)))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Thermal failsafe

@MainActor
private struct ThermalSection: View {
    @Bindable var controller: SleepController

    private static let limitMinutes = Int(ThermalFailsafe.defaultLimit / 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Thermal failsafe")
                Spacer()
                Toggle("Thermal failsafe", isOn: $controller.thermalFailsafeEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            Text("Turns No Sleep off if your Mac stays hot (serious or critical thermal state) for \(Self.limitMinutes) minutes in a row.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.thermalFailsafeEnabled {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    statusRow(now: context.date)
                }
            }
        }
    }

    @ViewBuilder
    private func statusRow(now: Date) -> some View {
        if let tripped = controller.thermalTrippedAt {
            StatusRow(
                systemImage: "thermometer.high", tint: .orange,
                text: "Turned off at \(tripped.formatted(date: .omitted, time: .shortened))",
                trailing: controller.thermalLockout ? "cooling down…" : "Mac cooled down"
            )
        } else if let remaining = controller.thermalFailsafe.remaining(now: now) {
            StatusRow(
                systemImage: "thermometer.high", tint: .orange,
                text: "Running hot · turns off in \(DurationParser.countdown(remaining))"
            )
        } else {
            StatusRow(
                systemImage: controller.thermalLevel.isHot ? "thermometer.high" : "thermometer.medium",
                tint: tint,
                text: "Temperature: \(controller.thermalLevel.displayName)"
            )
        }
    }

    private var tint: Color {
        switch controller.thermalLevel {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious, .critical: return .orange
        }
    }
}

// MARK: - Building blocks

@MainActor
struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

@MainActor
struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14)
    }
}

/// A full-width, menu-item-like row with hover highlight.
@MainActor
struct MenuActionRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
