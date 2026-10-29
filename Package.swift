// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VPNGuard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "Core"),
        // Root daemon + CLI. Foundation only, so it stays tiny in memory.
        .executableTarget(name: "vpnguardd", dependencies: ["Core"]),
        // Menu bar UI (AppKit), runs as the logged-in user.
        .executableTarget(name: "vpnguard-menu", dependencies: ["Core"]),
    ]
)
