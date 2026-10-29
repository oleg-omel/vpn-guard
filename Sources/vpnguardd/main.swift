import Foundation
import Core

func usage() -> Never {
    print("""
    vpnguardd daemon                 run the guard (root, started by launchd)
    vpnguardd status                 show current state
    vpnguardd check                  show which interface internet traffic uses right now
    vpnguardd list                   show protected apps and sites
    vpnguardd add-app <App.app>      add an app to the block list
    vpnguardd remove-app <name|path>
    vpnguardd add-site <domain|ip>   add a site to the block list
    vpnguardd remove-site <domain>
    vpnguardd add-wifi <ssid>        pause protection on this Wi-Fi network
    vpnguardd remove-wifi <ssid>
    vpnguardd enable | disable       turn protection on/off
    """)
    exit(2)
}

func edit(_ body: (inout Config) -> Bool) {
    var cfg = Config.load()
    guard body(&cfg) else { exit(1) }
    do { try cfg.save() } catch {
        fputs("cannot write \(configPath): \(error)\n", stderr)
        exit(1)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
let arg = args.count > 1 ? args[1] : nil

switch cmd {
case "daemon":
    Daemon().run()
case "status":
    if let s = Status.load(), s.isAlive {
        print("enabled=\(s.enabled) vpn=\(s.protected) iface=\(s.iface) blocking=\(s.blocking) trusted=\(s.trusted) ssid=\(s.ssid ?? "-") frozen=\(s.frozenProcesses)")
    } else {
        print("daemon not running")
    }
case "check":
    let c = Config.load()
    print("IPv4 -> \(routeInterface(to: c.probe4, v6: false) ?? "no route")")
    print("IPv6 -> \(routeInterface(to: c.probe6, v6: true) ?? "no route")")
case "list":
    let c = Config.load()
    print("enabled: \(c.enabled)")
    print("apps:"); c.apps.forEach { print("  \($0.name)  \($0.path)") }
    print("sites:"); c.sites.forEach { print("  \($0)") }
    print("trusted wifi:"); c.trustedSSIDs.forEach { print("  \($0)") }
case "add-app":
    guard let arg else { usage() }
    let url = URL(fileURLWithPath: arg).standardizedFileURL
    guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) else {
        fputs("not an .app bundle: \(arg)\n", stderr)
        exit(1)
    }
    edit { c in
        let entry = AppEntry(name: url.deletingPathExtension().lastPathComponent, path: url.path)
        if !c.apps.contains(entry) { c.apps.append(entry) }
        return true
    }
case "remove-app":
    guard let arg else { usage() }
    edit { $0.apps.removeAll { $0.name == arg || $0.path == arg }; return true }
case "add-site":
    guard let arg, let site = normalizeSite(arg) else { fputs("invalid site\n", stderr); exit(1) }
    edit { c in
        if !c.sites.contains(site) { c.sites.append(site) }
        return true
    }
case "remove-site":
    guard let arg, let site = normalizeSite(arg) else { fputs("invalid site\n", stderr); exit(1) }
    edit { $0.sites.removeAll { $0 == site }; return true }
case "add-wifi":
    guard let arg, !arg.isEmpty else { usage() }
    edit { c in
        if !c.trustedSSIDs.contains(arg) { c.trustedSSIDs.append(arg) }
        return true
    }
case "remove-wifi":
    guard let arg else { usage() }
    edit { $0.trustedSSIDs.removeAll { $0 == arg }; return true }
case "enable": edit { $0.enabled = true; return true }
case "disable": edit { $0.enabled = false; return true }
default: usage()
}
