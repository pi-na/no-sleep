import Foundation

/// Dotted numeric version ("1.10.2"), compared component by component.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Ignore pre-release/build suffixes ("1.2.0-beta" → 1.2.0).
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = String(text[..<cut]) }
        let parts = text.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.map { $0! }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The subset of GitHub's "latest release" API response we use.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int?
        /// "sha256:<hex>" when GitHub provides it.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }

        public init(name: String, browserDownloadURL: URL, size: Int? = nil, digest: String? = nil) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
            self.size = size
            self.digest = digest
        }

        public var sha256: String? {
            guard let digest, digest.hasPrefix("sha256:") else { return nil }
            return String(digest.dropFirst("sha256:".count)).lowercased()
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let htmlURL: URL?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public var version: AppVersion? { AppVersion(tagName) }
}

public enum UpdateAssetPicker {
    /// Chooses the DMG built for the newest macOS that is ≤ the running one, for this CPU.
    /// Asset names look like `NoSleep-1.2.0-macos26-apple-silicon.dmg` (or `…-universal.dmg`).
    public static func pick(_ assets: [GitHubRelease.Asset], macOSMajor: Int, isAppleSilicon: Bool) -> GitHubRelease.Asset? {
        var best: (asset: GitHubRelease.Asset, minimum: Int)?
        for asset in assets {
            let name = asset.name.lowercased()
            guard name.hasSuffix(".dmg"), name.hasPrefix("nosleep-") else { continue }
            let runsHere = name.contains("universal") || (isAppleSilicon && (name.contains("apple-silicon") || name.contains("arm64")))
                || (!isAppleSilicon && (name.contains("intel") || name.contains("x86_64")))
            guard runsHere, let minimum = minimumMacOS(in: name), minimum <= macOSMajor else { continue }
            if best == nil || minimum > best!.minimum { best = (asset, minimum) }
        }
        return best?.asset
    }

    /// `macos26` → 26.
    static func minimumMacOS(in name: String) -> Int? {
        guard let range = name.range(of: #"macos(\d+)"#, options: .regularExpression) else { return nil }
        return Int(name[range].dropFirst("macos".count))
    }
}
