import Darwin
import Foundation

/// Thin libproc helpers. Shared by the app and the hook CLI, so it has no other dependencies.
public enum ProcInfo {
    public static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    public static func name(_ pid: pid_t) -> String? {
        guard var info = bsdInfo(pid) else { return nil }
        let long = withUnsafeBytes(of: &info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !long.isEmpty { return long }
        return withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    public static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// "claude" / "codex" when this process is a coding agent. Claude Code runs from
    /// ~/.local/share/claude/versions/<version>, so its kernel name is the version number;
    /// the executable path is the reliable signal.
    public static func agentName(_ pid: pid_t) -> String? {
        if let n = name(pid)?.lowercased(), n == "claude" || n == "codex" { return n }
        guard let p = path(pid) else { return nil }
        let base = (p as NSString).lastPathComponent.lowercased()
        if base == "claude" || p.contains("/claude/versions/") { return "claude" }
        if base == "codex" { return "codex" }
        return nil
    }

    public static func parent(_ pid: pid_t) -> pid_t? {
        guard let info = bsdInfo(pid) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Controlling terminal like "ttys003", nil for background processes.
    public static func tty(_ pid: pid_t) -> String? {
        guard let info = bsdInfo(pid) else { return nil }
        let dev = info.e_tdev
        if dev == UInt32.max || dev == 0 { return nil }
        guard let p = devname(dev_t(bitPattern: dev), S_IFCHR) else { return nil }
        let s = String(cString: p)
        return s.hasPrefix("?") ? nil : s
    }

    public static func cwd(_ pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
        let s = withUnsafeBytes(of: &vpi.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return s.isEmpty ? nil : s
    }

    public static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = buf.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return got > 0 ? Array(buf.prefix(Int(got))).filter { $0 > 0 } : []
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Walks up from `start` (a hook process) to the agent that ran it.
    public static func agentAncestor(from start: pid_t) -> (pid: pid_t, name: String)? {
        var pid = start
        for _ in 0..<10 {
            guard pid > 1 else { return nil }
            if let n = agentName(pid) { return (pid, n) }
            guard let pp = parent(pid), pp != pid else { return nil }
            pid = pp
        }
        return nil
    }
}

public enum Paths {
    public static var home: String { NSHomeDirectory() }
    public static var supportDir: String { home + "/Library/Application Support/AgentCats" }
    public static var socket: String { supportDir + "/ev.sock" }
    public static var spool: String { supportDir + "/spool.jsonl" }
    public static var backups: String { supportDir + "/backups" }
    public static var claudeProjects: String { home + "/.claude/projects" }
    public static var claudeSettings: String { home + "/.claude/settings.json" }
    public static var codexHome: String { home + "/.codex" }
    public static var codexSessions: String { codexHome + "/sessions" }
    public static var codexHooks: String { codexHome + "/hooks.json" }
}
