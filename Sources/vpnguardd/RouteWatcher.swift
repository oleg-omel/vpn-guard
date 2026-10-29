import Foundation

/// Wakes us only when the kernel routing table or an interface changes (PF_ROUTE socket); no polling.
final class RouteWatcher {
    private let fd: Int32
    private var source: DispatchSourceRead?
    var onChange: (() -> Void)?

    init?() {
        fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        if fd < 0 { return nil }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }

    func start() {
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in self?.drain() }
        s.resume()
        source = s
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var relevant = false
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 16 { break }
            let type = buf[3]  // rt_msghdr.rtm_type
            let flags = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int32.self) }  // rtm_flags
            switch type {
            case 0x0c, 0x0d, 0x0e, 0x12:  // NEWADDR, DELADDR, IFINFO, IFINFO2
                relevant = true
            case 0x01, 0x02, 0x03:  // ADD, DELETE, CHANGE — skip ARP/ND and cloned host routes
                if flags & (0x400 | 0x20000) == 0 { relevant = true }
            default:
                break
            }
        }
        if relevant { onChange?() }
    }
}

func routeInterface(to ip: String, v6: Bool) -> String? {
    let r = run("/sbin/route", ["-n", "get"] + (v6 ? ["-inet6"] : []) + [ip])
    guard r.status == 0 else { return nil }
    for line in r.out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("interface:") { return t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces) }
    }
    return nil
}
