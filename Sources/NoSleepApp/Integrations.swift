import AppKit
import Foundation
import NoSleepCore
import Observation

/// Installs the hooks that let agents (Claude Code, Codex — and T3 Code threads, which run on
/// top of them) keep the Mac awake while they work.
@MainActor
@Observable
final class Integrations {
    private(set) var claudeStatus: HookInstaller.Status = .notInstalled
    private(set) var codexStatus: HookInstaller.Status = .notInstalled
    private(set) var cliLinked = false
    var lastError: String?

    /// Path of the bundled CLI (`NoSleep.app/Contents/Helpers/nosleep`).
    let cliPath: String = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nosleep").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        // Running unbundled (swift run): use the sibling build product.
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("nosleep").path
    }()

    let cliLinkPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/nosleep").path

    var codexInstalledOnSystem: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
    }

    var claudeInstalledOnSystem: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
    }

    var anyAgentInstalled: Bool { claudeStatus != .notInstalled || codexStatus != .notInstalled }
    var allAgentsInstalled: Bool { claudeStatus == .installed && codexStatus == .installed }

    func installer(for agent: AgentKind) -> HookInstaller {
        HookInstaller(agent: agent, cliPath: cliPath)
    }

    func status(for agent: AgentKind) -> HookInstaller.Status {
        agent == .claude ? claudeStatus : codexStatus
    }

    func refresh() {
        claudeStatus = installer(for: .claude).status()
        codexStatus = installer(for: .codex).status()
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: cliLinkPath)
        cliLinked = destination == cliPath
    }

    func install(_ agent: AgentKind) {
        perform { try self.installer(for: agent).install() }
    }

    /// Same as `nosleep connect all`: Claude Code + Codex (which also covers T3 Code threads).
    func connectAll() {
        perform {
            for agent in AgentKind.allCases { try self.installer(for: agent).install() }
        }
    }

    /// Same as `nosleep disconnect all`.
    func disconnectAll() {
        perform {
            for agent in AgentKind.allCases { try self.installer(for: agent).uninstall() }
        }
    }

    func uninstall(_ agent: AgentKind) {
        perform { try self.installer(for: agent).uninstall() }
    }

    func reveal(_ agent: AgentKind) {
        NSWorkspace.shared.activateFileViewerSelecting([installer(for: agent).configURL])
    }

    func linkCLI() {
        perform {
            let fileManager = FileManager.default
            let link = URL(fileURLWithPath: self.cliLinkPath)
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fileManager.removeItem(at: link)
            } else if fileManager.fileExists(atPath: link.path) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: link.path])
            }
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: self.cliPath)
        }
    }

    func unlinkCLI() {
        perform {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: self.cliLinkPath)) != nil {
                try FileManager.default.removeItem(atPath: self.cliLinkPath)
            }
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = (error as? JSONValue.ParseError)?.description ?? error.localizedDescription
        }
        refresh()
    }
}
