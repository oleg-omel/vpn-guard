import Foundation

public let supportDir = "/Library/Application Support/VPNGuard"
public let configPath = supportDir + "/config.json"
public let statusPath = supportDir + "/status.json"
public let ssidPath = supportDir + "/ssid.json"

/// Current Wi-Fi name as seen by the menu bar app (the only process macOS lets read it, given Location permission).
public struct SSIDReport: Codable {
    public var pid: Int32
    public var ssid: String?
    public init(pid: Int32, ssid: String?) {
        self.pid = pid
        self.ssid = ssid
    }

    public static func load() -> SSIDReport? {
        guard let data = FileManager.default.contents(atPath: ssidPath) else { return nil }
        return try? JSONDecoder().decode(SSIDReport.self, from: data)
    }

    public func save() {
        try? JSONEncoder().encode(self).write(to: URL(fileURLWithPath: ssidPath), options: .atomic)
    }
}

public struct AppEntry: Codable, Equatable, Hashable {
    public var name: String
    public var path: String
    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct Config: Codable, Equatable {
    public var enabled = true
    public var apps: [AppEntry] = []
    public var sites: [String] = []
    /// Interface name prefixes that count as "a VPN tunnel".
    public var tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
    /// Public addresses used to ask the routing table where internet traffic goes.
    public var probe4 = "1.1.1.1"
    public var probe6 = "2606:4700:4700::1111"
    /// Block while there is no route at all (fail closed), so nothing leaks when the network comes back.
    public var blockWhenOffline = true
    /// Wi-Fi networks (SSID) where protection is paused automatically.
    public var trustedSSIDs: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        apps = try c.decodeIfPresent([AppEntry].self, forKey: .apps) ?? d.apps
        sites = try c.decodeIfPresent([String].self, forKey: .sites) ?? d.sites
        tunnelPrefixes = try c.decodeIfPresent([String].self, forKey: .tunnelPrefixes) ?? d.tunnelPrefixes
        probe4 = try c.decodeIfPresent(String.self, forKey: .probe4) ?? d.probe4
        probe6 = try c.decodeIfPresent(String.self, forKey: .probe6) ?? d.probe6
        blockWhenOffline = try c.decodeIfPresent(Bool.self, forKey: .blockWhenOffline) ?? d.blockWhenOffline
        trustedSSIDs = try c.decodeIfPresent([String].self, forKey: .trustedSSIDs) ?? d.trustedSSIDs
    }

    private enum Keys: String, CodingKey {
        case enabled, apps, sites, tunnelPrefixes, probe4, probe6, blockWhenOffline, trustedSSIDs
    }

    public static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: configPath),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }
}

public struct Status: Codable, Equatable {
    public var pid: Int32
    public var enabled: Bool
    public var protected: Bool
    public var iface: String
    public var blocking: Bool
    public var frozenProcesses: Int
    /// Current Wi-Fi network name, if known.
    public var ssid: String?
    /// Connected to a trusted Wi-Fi, protection paused.
    public var trusted: Bool

    public init(pid: Int32, enabled: Bool, protected: Bool, iface: String, blocking: Bool, frozenProcesses: Int, ssid: String?, trusted: Bool) {
        self.pid = pid
        self.enabled = enabled
        self.protected = protected
        self.iface = iface
        self.blocking = blocking
        self.frozenProcesses = frozenProcesses
        self.ssid = ssid
        self.trusted = trusted
    }

    /// True if the daemon process exists (EPERM means it exists but belongs to root).
    public var isAlive: Bool { kill(pid, 0) == 0 || errno == EPERM }

    public static func load() -> Status? {
        guard let data = FileManager.default.contents(atPath: statusPath) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    public func save() {
        try? JSONEncoder().encode(self).write(to: URL(fileURLWithPath: statusPath), options: .atomic)
    }
}

public func isIPLiteral(_ s: String) -> Bool {
    var a4 = in_addr(), a6 = in6_addr()
    return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
}

/// Turns user input ("https://Example.com/path") into a bare lowercase host, or nil if it isn't a valid host/IP.
public func normalizeSite(_ input: String) -> String? {
    var t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if isIPLiteral(t) { return t }
    if t.contains("://") { t = URLComponents(string: t)?.host ?? "" }
    else if let i = t.firstIndex(where: { "/:?#".contains($0) }) { t = String(t[..<i]) }
    if t.hasPrefix("*.") { t.removeFirst(2) }
    if t.hasSuffix(".") { t.removeLast() }
    let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
    guard t.count <= 253, t.range(of: "^\(label)(\\.\(label))+$", options: .regularExpression) != nil else { return nil }
    return t
}
