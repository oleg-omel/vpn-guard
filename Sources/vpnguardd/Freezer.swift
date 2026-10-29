import Foundation
import Core

/// Per-app "no internet" without a Network Extension: processes living inside a listed .app bundle are
/// SIGSTOPped (they cannot send a single packet) and SIGCONTed once the VPN is back.
final class Freezer {
    private var frozen: [pid_t: String] = [:]
    var count: Int { frozen.count }

    private func prefixes(_ apps: [AppEntry]) -> [String] {
        apps.map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
    }

    private func allPids() -> [pid_t] {
        let slots = Int(proc_listallpids(nil, 0)) * 2 + 256
        var pids = [pid_t](repeating: 0, count: slots)
        let n = Int(proc_listallpids(&pids, Int32(slots * MemoryLayout<pid_t>.size)))
        return n > 0 ? pids.prefix(n).filter { $0 > 0 } : []
    }

    private func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// Freeze every matching process (including ones launched since the last call); release stale ones.
    func sync(_ apps: [AppEntry]) {
        let pre = prefixes(apps)
        for (pid, p) in frozen {
            if kill(pid, 0) != 0 {
                frozen[pid] = nil
            } else if !pre.contains(where: { p.hasPrefix($0) }) {
                kill(pid, SIGCONT)
                frozen[pid] = nil
            }
        }
        guard !pre.isEmpty else { return }
        let me = getpid()
        for pid in allPids() where pid != me && frozen[pid] == nil {
            guard let p = path(of: pid), pre.contains(where: { p.hasPrefix($0) }) else { continue }
            if kill(pid, SIGSTOP) == 0 { frozen[pid] = p }
        }
    }

    /// Resume everything we froze, plus any leftover stopped process of listed apps (e.g. after a daemon crash).
    func resumeAll(_ apps: [AppEntry]) {
        for pid in frozen.keys { kill(pid, SIGCONT) }
        frozen.removeAll()
        let pre = prefixes(apps)
        guard !pre.isEmpty else { return }
        for pid in allPids() {
            if let p = path(of: pid), pre.contains(where: { p.hasPrefix($0) }) { kill(pid, SIGCONT) }
        }
    }
}
