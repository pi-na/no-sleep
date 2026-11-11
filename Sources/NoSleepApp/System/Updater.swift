import AppKit
import CryptoKit
import Foundation
import NoSleepCore
import Observation
import os
import Security

private let log = Logger(subsystem: "com.tomaspinausig.nosleep", category: "updates")

/// Self-updates from GitHub Releases — no server of our own.
///
/// Trust model: a downloaded build is installed only if its code signature satisfies *this* app's
/// designated requirement (same bundle ID, same signing certificate), or one of the extra
/// requirements listed under `NoSleepUpdateRequirements` in Info.plist (used to hand over to a new
/// signing identity, e.g. Developer ID). GitHub's SHA-256 digest is checked too when present.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        /// A newer version exists, but there's no download for this Mac's macOS/CPU.
        case unsupported(version: String)
        case downloading
        case installing
        case failed(String)
    }

    private enum Keys {
        static let autoCheck = "updatesAutoCheck"
        static let autoInstall = "updatesAutoInstall"
        static let lastChecked = "updatesLastChecked"
        static let feedOverride = "updateFeedURL"
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? {
        didSet { defaults.set(lastChecked, forKey: Keys.lastChecked) }
    }
    private(set) var releaseURL: URL?

    var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Keys.autoCheck); schedule() }
    }

    var automaticallyInstalls: Bool {
        didSet { defaults.set(automaticallyInstalls, forKey: Keys.autoInstall) }
    }

    /// Called right before the app quits to relaunch the new version.
    var willRelaunch: (() -> Void)?

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    private let defaults = UserDefaults.standard
    private var pending: GitHubRelease.Asset?
    private var timer: Timer?
    private static let checkInterval: TimeInterval = 6 * 3600

    init() {
        defaults.register(defaults: [Keys.autoCheck: true, Keys.autoInstall: true])
        automaticallyChecks = defaults.bool(forKey: Keys.autoCheck)
        automaticallyInstalls = defaults.bool(forKey: Keys.autoInstall)
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var feedURL: URL {
        if let override = defaults.string(forKey: Keys.feedOverride), let url = URL(string: override) {
            return url
        }
        let repository = Bundle.main.infoDictionary?["NoSleepUpdateRepository"] as? String ?? "pi-na/no-sleep"
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    func start() {
        schedule()
        // First check shortly after launch, then every few hours.
        guard automaticallyChecks else { return }
        let due = (lastChecked ?? .distantPast).addingTimeInterval(Self.checkInterval) <= Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + (due ? 20 : Self.checkInterval)) { [weak self] in
            guard let self, self.automaticallyChecks else { return }
            self.checkNow()
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automaticallyChecks else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        timer.tolerance = 600
        self.timer = timer
    }

    // MARK: Check

    func checkNow() {
        guard !isBusy else { return }
        state = .checking
        Task { await check() }
    }

    private func check() async {
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("NoSleep/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError("GitHub answered \(http.statusCode)")
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            lastChecked = Date()
            releaseURL = release.htmlURL

            guard !release.draft, !release.prerelease, let latest = release.version,
                  let current = AppVersion(currentVersion), latest > current
            else {
                state = .upToDate
                log.info("up to date (\(self.currentVersion, privacy: .public))")
                return
            }
            let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            guard let asset = UpdateAssetPicker.pick(release.assets, macOSMajor: osMajor, isAppleSilicon: Self.isAppleSilicon)
            else {
                state = .unsupported(version: latest.description)
                log.info("\(latest.description, privacy: .public) available but no asset for macOS \(osMajor)")
                return
            }
            pending = asset
            state = .available(version: latest.description)
            log.info("update \(latest.description, privacy: .public) available: \(asset.name, privacy: .public)")
            if automaticallyInstalls { await install() }
        } catch {
            state = .failed(error.localizedDescription)
            log.error("check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Install

    func installNow() {
        guard !isBusy, pending != nil else { return }
        Task { await install() }
    }

    private func install() async {
        guard let asset = pending else { return }
        do {
            state = .downloading
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("NoSleepUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            let (downloaded, _) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            if let expected = asset.sha256 {
                let actual = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw UpdateError("The download is corrupted (checksum mismatch).") }
            }

            state = .installing
            let target = Bundle.main.bundleURL
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.install(dmg: dmg, replacing: target, workDirectory: work)
            }.value
            log.info("installed \(asset.name, privacy: .public); relaunching")
            relaunch()
        } catch {
            state = .failed(error.localizedDescription)
            log.error("install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Wait for this process to exit, then open the (already replaced) bundle.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path]
        do {
            try process.run()
        } catch {
            state = .failed("Installed, but couldn't relaunch. Open No Sleep again.")
            return
        }
        willRelaunch?()
        NSApp.terminate(nil)
    }

    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The blocking part of an update: mount, verify, swap in place.
enum UpdateInstaller {
    static func install(dmg: URL, replacing target: URL, workDirectory: URL) throws {
        let mountPoint = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path],
                failure: "Couldn't open the downloaded disk image.")
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], failure: "") }

        guard let newApp = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError("The update doesn't contain the app.") }

        let info = Bundle(url: newApp)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("The update is for a different app.")
        }
        try CodeTrust.verify(newApp)

        // Stage next to the target (same volume) so the final swap is atomic.
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("No permission to update the app in \(parent.path).")
        }
        let staged = parent.appendingPathComponent(".NoSleep-update-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", [newApp.path, staged.path], failure: "Couldn't copy the update.")
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError("Couldn't replace the app: \(error.localizedDescription)")
        }
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String], failure: String) throws -> String {
        let result = LidSleepControl.run(path, arguments)
        guard result.status == 0 else { throw UpdateError(failure) }
        return result.output
    }
}

/// Code-signature checks for downloaded updates.
enum CodeTrust {
    static func verify(_ app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, SecCSFlags(), &selfStatic) == errSecSuccess, let selfStatic
        else { throw UpdateError("Couldn't read this app's signature.") }
        var ownRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, SecCSFlags(), &ownRequirement) == errSecSuccess,
              let ownRequirement
        else { throw UpdateError("This copy of No Sleep isn't signed, so it can't verify updates.") }

        var text: CFString?
        SecRequirementCopyString(ownRequirement, SecCSFlags(), &text)
        if (text as String?)?.contains("cdhash") == true {
            throw UpdateError("This copy of No Sleep is ad-hoc signed, so it can't verify updates.")
        }

        var requirements = [ownRequirement]
        for string in Bundle.main.infoDictionary?["NoSleepUpdateRequirements"] as? [String] ?? [] {
            var requirement: SecRequirement?
            if SecRequirementCreateWithString(string as CFString, SecCSFlags(), &requirement) == errSecSuccess,
               let requirement {
                requirements.append(requirement)
            }
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError("Couldn't read the update's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        for requirement in requirements where SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess {
            return
        }
        throw UpdateError("The update isn't signed by the No Sleep developer. Skipped it.")
    }
}
