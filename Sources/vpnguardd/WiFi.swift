import Foundation
import Core

/// Wi-Fi interface name (e.g. en0), looked up once.
let wifiInterface: String? = {
    let out = run("/usr/sbin/networksetup", ["-listallhardwareports"]).out
    var seen = false
    for line in out.split(separator: "\n") {
        if line.hasPrefix("Hardware Port:") { seen = line.contains("Wi-Fi") }
        else if seen, line.hasPrefix("Device:") { return line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces) }
    }
    return nil
}()

/// Current SSID, as reported by the menu bar app (macOS hides it from root and from bare binaries).
func currentSSID() -> String? {
    guard let r = SSIDReport.load(), kill(r.pid, 0) == 0 else { return nil }
    return r.ssid
}
