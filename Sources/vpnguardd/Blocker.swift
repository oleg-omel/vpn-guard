import Foundation
import Core

/// Site blocking: /etc/hosts sinkhole for the names + a pf anchor dropping the resolved IPs.
final class Blocker {
    private let anchor = "com.apple/vpnguard"
    private let hostsPath = "/private/etc/hosts"
    private let begin = "# BEGIN VPNGUARD", end = "# END VPNGUARD"
    private var pfToken: String?
    private var applied: String?

    func apply(domains: [String], ips: [String]) {
        let key = domains.joined(separator: ",") + "|" + ips.joined(separator: ",")
        guard key != applied else { return }
        applied = key
        setHosts(domains)
        loadPF(ips)
    }

    func clear() {
        applied = nil
        setHosts([])
        run("/sbin/pfctl", ["-a", anchor, "-F", "all"])
        if let t = pfToken {
            run("/sbin/pfctl", ["-X", t])
            pfToken = nil
        }
    }

    private func loadPF(_ ips: [String]) {
        if ips.isEmpty {
            run("/sbin/pfctl", ["-a", anchor, "-F", "all"])
            return
        }
        if pfToken == nil {
            let r = run("/sbin/pfctl", ["-E"])
            if let range = r.err.range(of: "Token : ") {
                pfToken = String(r.err[range.upperBound...].prefix { $0.isNumber })
            }
        }
        let rules = """
        table <vg_sites> persist { \(ips.joined(separator: ", ")) }
        block drop quick from any to <vg_sites>
        block drop quick from <vg_sites> to any

        """
        let r = run("/sbin/pfctl", ["-a", anchor, "-f", "-"], input: rules)
        if r.status != 0 { log("pfctl failed: \(r.err)") }
    }

    private func setHosts(_ domains: [String]) {
        guard let text = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return }
        var lines: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(begin) { skipping = true; continue }
            if line.hasPrefix(end) { skipping = false; continue }
            if !skipping { lines.append(line) }
        }
        while lines.last == "" { lines.removeLast() }
        var out = lines.joined(separator: "\n") + "\n"
        let names = domains.filter { !isIPLiteral($0) }
        if !names.isEmpty {
            out += begin + "\n"
            for d in names {
                for h in d.hasPrefix("www.") ? [d] : [d, "www." + d] {
                    out += "0.0.0.0 \(h)\n:: \(h)\n"
                }
            }
            out += end + "\n"
        }
        guard out != text else { return }
        do {
            try out.write(toFile: hostsPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hostsPath)
        } catch {
            log("hosts write failed: \(error)")
            return
        }
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }
}
