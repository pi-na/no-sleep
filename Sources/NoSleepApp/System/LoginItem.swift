import Foundation
import os
import ServiceManagement

private let log = Logger(subsystem: "com.tomaspinausig.nosleep", category: "login-item")

enum LoginItem {
    /// What the user chose. macOS ties the registration to the app's code signature, so if the
    /// signature ever changes (e.g. a differently-signed update) the registration can vanish;
    /// we remember the intent and quietly restore it on launch.
    private static let wantedKey = "launchAtLoginWanted"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        UserDefaults.standard.set(enabled, forKey: wantedKey)
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Called at launch: re-register only if the user wanted it and it got lost.
    static func restoreIfNeeded() {
        let defaults = UserDefaults.standard
        let status = SMAppService.mainApp.status
        log.info("launch: login item status=\(status.rawValue, privacy: .public) wanted=\(defaults.bool(forKey: wantedKey), privacy: .public)")
        if defaults.object(forKey: wantedKey) == nil {
            // First run of a build that tracks intent: adopt the current state.
            defaults.set(status == .enabled, forKey: wantedKey)
            return
        }
        // `.notFound` is what macOS reports when the registration belongs to a differently-signed build.
        if defaults.bool(forKey: wantedKey), status == .notRegistered || status == .notFound {
            do {
                try SMAppService.mainApp.register()
                log.info("restored login item, status=\(SMAppService.mainApp.status.rawValue, privacy: .public)")
            } catch {
                log.error("could not restore login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
