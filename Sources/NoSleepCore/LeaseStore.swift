import Darwin
import notify
import Foundation

public final class LeaseStore {
    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL = NoSleepPaths.leasesDirectory) {
        self.directory = directory
    }

    /// Lease IDs come from external tools; keep file names safe and bounded.
    public static func sanitize(id: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var result = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { result = "lease" }
        return String(result.prefix(120))
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(Self.sanitize(id: id) + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func lease(id: String) -> Lease? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? Self.decoder.decode(Lease.self, from: data)
    }

    /// Creates or refreshes a lease. Returns the stored lease and whether it is new.
    @discardableResult
    public func upsert(
        id: String, source: String, label: String? = nil, detail: String? = nil,
        pid: Int32? = nil, ttl: TimeInterval? = nil, now: Date = Date()
    ) throws -> (lease: Lease, created: Bool) {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let sanitizedID = Self.sanitize(id: id)
        let existing = lease(id: sanitizedID)
        let startTime = pid.flatMap { ProcessInspector.snapshot(of: $0)?.startTime }

        // Keep the original creation date only if it is the same owner (same process).
        let sameOwner = existing.map { $0.pid == pid && $0.validity(now: now) == .valid } ?? false
        let lease = Lease(
            id: sanitizedID,
            source: source,
            label: label ?? existing?.label,
            detail: detail ?? existing?.detail,
            pid: pid,
            pidStartTime: startTime,
            createdAt: sameOwner ? existing!.createdAt : now,
            updatedAt: now,
            expiresAt: ttl.map { now.addingTimeInterval($0) }
        )
        let data = try Self.encoder.encode(lease)
        try data.write(to: url(for: sanitizedID), options: .atomic)
        return (lease, !sameOwner)
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        (try? fileManager.removeItem(at: url(for: id))) != nil
    }

    public func removeAll() {
        for file in leaseFiles() { try? fileManager.removeItem(at: file) }
    }

    private func leaseFiles() -> [URL] {
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    /// All leases on disk (malformed files are ignored).
    public func all() -> [Lease] {
        leaseFiles()
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decoder.decode(Lease.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Deletes expired / orphaned leases and returns the valid ones.
    public func pruneAndList(
        now: Date = Date(),
        isProcessAlive: (Int32, Double?) -> Bool = ProcessInspector.isAlive
    ) -> [Lease] {
        var valid: [Lease] = []
        for file in leaseFiles() {
            guard let data = try? Data(contentsOf: file),
                  let lease = try? Self.decoder.decode(Lease.self, from: data)
            else {
                // Drop unreadable files older than a minute (avoid racing a writer).
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, now.timeIntervalSince(modified) > 60 { try? fileManager.removeItem(at: file) }
                continue
            }
            if lease.validity(now: now, isProcessAlive: isProcessAlive) == .valid {
                valid.append(lease)
            } else {
                try? fileManager.removeItem(at: file)
            }
        }
        return valid.sorted { $0.createdAt < $1.createdAt }
    }

    /// Tell the running app to re-read leases immediately.
    public static func postChanged() {
        notify_post(NoSleepConstants.leasesChangedNotification)
    }
}
