import Foundation
import Core

final class Daemon {
    private var cfg = Config.load()
    private let freezer = Freezer()
    private let blocker = Blocker()
    private var routes: RouteWatcher?
    private var debounce: DispatchWorkItem?
    private var scanTimer: DispatchSourceTimer?
    private var safetyTimer: DispatchSourceTimer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var signals: [DispatchSourceSignal] = []
    private var blocking = false
    private var refreshedThisBlock = false
    private var lastStatus: Status?
    private var ipCache: [String: Set<String>] = [:]

    func run() -> Never {
        guard getuid() == 0 else {
            log("vpnguardd daemon must run as root")
            exit(1)
        }
        guard let routes = RouteWatcher() else {
            log("cannot open routing socket")
            exit(1)
        }
        self.routes = routes

        // Recover from a previous crash: nothing should stay frozen or blocked.
        freezer.resumeAll(cfg.apps)
        blocker.clear()

        routes.onChange = { [weak self] in self?.schedule() }
        routes.start()
        watchConfig()
        installSignalHandlers()

        // Rare safety net (coalesced by the OS) in case a routing event is ever missed, e.g. around sleep.
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 120, repeating: 120, leeway: .seconds(60))
        t.setEventHandler { [weak self] in self?.evaluate() }
        t.resume()
        safetyTimer = t

        refreshIPs(nil)
        evaluate()
        dispatchMain()
    }

    // MARK: - Triggers

    private func schedule(_ delay: TimeInterval = 0.4) {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.evaluate() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func watchConfig() {
        let fd = open(supportDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let new = Config.load()
            if new != self.cfg {
                self.cfg = new
                self.refreshIPs(nil)
            }
            self.schedule(0.2)  // also covers a new ssid.json
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        dirSource = s
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                self?.release()
                try? FileManager.default.removeItem(atPath: statusPath)
                exit(0)
            }
            s.resume()
            signals.append(s)
        }
    }

    // MARK: - Decision

    private func evaluate() {
        let p = probe()
        let ssid = currentSSID()
        // Trusted only when internet traffic actually leaves through the Wi-Fi interface.
        let trusted = ssid.map { cfg.trustedSSIDs.contains($0) } == true && p.iface == wifiInterface
        if cfg.enabled && !p.protected && !trusted { engage() } else { release() }
        let st = Status(pid: getpid(), enabled: cfg.enabled, protected: p.protected, iface: p.iface,
                        blocking: blocking, frozenProcesses: freezer.count, ssid: ssid, trusted: trusted)
        if st != lastStatus {
            lastStatus = st
            st.save()
            log("vpn=\(p.protected) iface=\(p.iface) ssid=\(ssid ?? "-") trusted=\(trusted) blocking=\(blocking) frozen=\(freezer.count)")
        }
    }

    /// Asks the routing table where public internet traffic would leave; protected only if every family used goes via a tunnel.
    private func probe() -> (protected: Bool, iface: String) {
        let i4 = routeInterface(to: cfg.probe4, v6: false)
        let i6 = routeInterface(to: cfg.probe6, v6: true)
        let found = [i4, i6].compactMap { $0 }
        guard !found.isEmpty else { return (!cfg.blockWhenOffline, "offline") }
        let isTunnel = { (name: String) in
            self.cfg.tunnelPrefixes.contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy(\.isNumber) }
        }
        return (found.allSatisfy(isTunnel), i4 ?? i6 ?? "?")
    }

    // MARK: - Blocking

    private func engage() {
        if !blocking {
            blocking = true
            refreshedThisBlock = false
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.freezer.sync(self.cfg.apps)
            }
            t.resume()
            scanTimer = t
        }
        freezer.sync(cfg.apps)
        applySites()
        if !refreshedThisBlock {
            refreshedThisBlock = true
            refreshIPs { [weak self] in
                guard let self, self.blocking else { return }
                self.applySites()
            }
        }
    }

    private func release() {
        guard blocking else {
            if lastStatus == nil { freezer.resumeAll(cfg.apps) }
            return
        }
        blocking = false
        scanTimer?.cancel()
        scanTimer = nil
        freezer.resumeAll(cfg.apps)
        blocker.clear()
        refreshIPs(nil)
    }

    private var siteNames: [String] { cfg.sites.compactMap(normalizeSite) }

    private func applySites() {
        var ips = Set<String>()
        for s in siteNames {
            if isIPLiteral(s) { ips.insert(s) } else {
                ips.formUnion(ipCache[s] ?? [])
                ips.formUnion(ipCache["www." + s] ?? [])
            }
        }
        blocker.apply(domains: siteNames, ips: ips.sorted())
    }

    /// Resolve site names off the main thread (only meaningful while no hosts sinkhole is active).
    private func refreshIPs(_ done: (() -> Void)?) {
        let names = siteNames.filter { !isIPLiteral($0) }.flatMap { $0.hasPrefix("www.") ? [$0] : [$0, "www." + $0] }
        guard !names.isEmpty else { done?(); return }
        DispatchQueue.global(qos: .utility).async {
            let result = names.map { ($0, resolve($0)) }
            DispatchQueue.main.async {
                for (n, ips) in result where !ips.isEmpty { self.ipCache[n, default: []].formUnion(ips) }
                done?()
            }
        }
    }
}

func resolve(_ host: String) -> Set<String> {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
    defer { freeaddrinfo(res) }
    var out = Set<String>()
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let ai = p {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
            let s = String(cString: buf)
            if s != "0.0.0.0", s != "::", s != "::1", !s.hasPrefix("127."), !s.contains("%") { out.insert(s) }
        }
        p = ai.pointee.ai_next
    }
    return out
}
