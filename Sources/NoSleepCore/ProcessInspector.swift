import Darwin
import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    /// Process start time (seconds since 1970). Used to detect PID reuse.
    public let startTime: Double
}

public enum ProcessInspector {
    /// Shells and wrappers we walk through when looking for the agent process that ran a hook.
    public static let wrapperNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh",
        "env", "nosleep", "timeout", "gtimeout", "nohup", "xargs", "sudo",
    ]

    public static func snapshot(of pid: Int32) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }

        let name = withUnsafePointer(to: info.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let start = info.kp_proc.p_un.__p_starttime
        return ProcessSnapshot(
            pid: pid,
            parentPID: info.kp_eproc.e_ppid,
            name: name,
            startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        )
    }

    /// True when `pid` is alive and (if given) still has the same start time.
    public static func isAlive(pid: Int32, startTime: Double?) -> Bool {
        guard let snapshot = snapshot(of: pid) else { return false }
        if snapshot.name.isEmpty { return false }
        guard let startTime else { return true }
        return abs(snapshot.startTime - startTime) < 1.0
    }

    /// Walks up from `pid` skipping shells/wrappers and returns the first "real" ancestor:
    /// for a hook command this is the Claude Code / Codex process that spawned it.
    public static func agentAncestor(startingAt pid: Int32) -> ProcessSnapshot? {
        var current = pid
        for _ in 0..<12 {
            guard current > 1, let snapshot = snapshot(of: current) else { return nil }
            if !wrapperNames.contains(snapshot.name.lowercased()) {
                return snapshot
            }
            current = snapshot.parentPID
        }
        return nil
    }
}
