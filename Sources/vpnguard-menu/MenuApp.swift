import AppKit
import Core
import CoreLocation
import CoreWLAN

/// Menu bar UI. Fully event driven: it redraws only when the daemon rewrites status.json or the menu is opened.
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate, CLLocationManagerDelegate, CWEventDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var watcher: DispatchSourceFileSystemObject?
    private let location = CLLocationManager()
    private var lastPublished: String??

    private var locationOK: Bool {
        let s = location.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    private var ssid: String? { locationOK ? CWWiFiClient.shared().interface()?.ssid() : nil }

    /// Tell the daemon which Wi-Fi we are on (it cannot read the name itself).
    private func publishSSID() {
        let cur = ssid
        if let last = lastPublished, last == cur { return }
        lastPublished = .some(cur)
        SSIDReport(pid: getpid(), ssid: cur).save()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { publishSSID() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { publishSSID() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { publishSSID() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        location.delegate = self
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        CWWiFiClient.shared().delegate = self
        try? CWWiFiClient.shared().startMonitoringEvent(with: .ssidDidChange)
        try? CWWiFiClient.shared().startMonitoringEvent(with: .linkDidChange)
        publishSSID()
        let fd = open(supportDir, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            s.setEventHandler { [weak self] in self?.updateIcon() }
            s.setCancelHandler { close(fd) }
            s.resume()
            watcher = s
        }
    }

    private var liveStatus: Status? {
        guard let s = Status.load(), s.isAlive else { return nil }
        return s
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(atPath: ssidPath)
    }

    private func updateIcon() {
        let symbol: String
        if let s = liveStatus {
            symbol = !s.enabled || s.trusted ? "shield.slash" : s.blocking ? "exclamationmark.shield.fill" : "lock.shield.fill"
        } else {
            symbol = "questionmark.circle"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "VPN Guard")
        img?.isTemplate = true
        item.button?.image = img
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateIcon()
        let cfg = Config.load()
        menu.removeAllItems()

        let title: String
        if let s = liveStatus {
            if !s.enabled { title = "Защита выключена" }
            else if s.trusted { title = "Доверенная сеть «\(s.ssid ?? "")» — защита приостановлена" }
            else if s.blocking { title = "Нет VPN (\(s.iface)) — доступ заблокирован" }
            else { title = "Трафик идёт через VPN (\(s.iface))" }
        } else {
            title = "Служба vpnguardd не запущена"
        }
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        let toggle = menu.addItem(withTitle: "Защита включена", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = cfg.enabled ? .on : .off
        menu.addItem(.separator())

        menu.addItem(withTitle: "Приложения", action: nil, keyEquivalent: "").isEnabled = false
        for a in cfg.apps {
            let it = menu.addItem(withTitle: a.name, action: nil, keyEquivalent: "")
            it.image = NSWorkspace.shared.icon(forFile: a.path).resized(16)
            it.submenu = removeMenu(#selector(removeApp(_:)), key: a.path)
        }
        let addApp = menu.addItem(withTitle: "Добавить приложение…", action: #selector(addApp), keyEquivalent: "")
        addApp.target = self
        menu.addItem(.separator())

        menu.addItem(withTitle: "Сайты", action: nil, keyEquivalent: "").isEnabled = false
        for s in cfg.sites {
            let it = menu.addItem(withTitle: s, action: nil, keyEquivalent: "")
            it.submenu = removeMenu(#selector(removeSite(_:)), key: s)
        }
        let addSite = menu.addItem(withTitle: "Добавить сайт…", action: #selector(addSite), keyEquivalent: "")
        addSite.target = self
        menu.addItem(.separator())

        menu.addItem(.separator())
        let wifi = menu.addItem(withTitle: "Доверенные Wi-Fi (защита выключена)", action: nil, keyEquivalent: "")
        wifi.submenu = wifiMenu(cfg)
        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Скрыть значок", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
    }

    private func removeMenu(_ action: Selector, key: String) -> NSMenu {
        let m = NSMenu()
        let r = m.addItem(withTitle: "Удалить из списка", action: action, keyEquivalent: "")
        r.target = self
        r.representedObject = key
        return m
    }

    // MARK: - Actions

    private func modify(_ body: (inout Config) -> Void) {
        var cfg = Config.load()
        body(&cfg)
        do { try cfg.save() } catch {
            let a = NSAlert()
            a.messageText = "Не удалось сохранить список"
            a.informativeText = "\(error.localizedDescription)\n\(configPath)"
            a.runModal()
        }
    }

    @objc private func toggleEnabled() { modify { $0.enabled.toggle() } }

    @objc private func removeApp(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        modify { $0.apps.removeAll { $0.path == p } }
    }

    @objc private func removeSite(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        modify { $0.sites.removeAll { $0 == s } }
    }

    @objc private func openLocationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }

    @objc private func toggleWifi(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        modify { cfg in
            if let i = cfg.trustedSSIDs.firstIndex(of: s) { cfg.trustedSSIDs.remove(at: i) } else { cfg.trustedSSIDs.append(s) }
        }
    }

    /// Known (preferred) networks of the Mac plus any trusted ones no longer known; checkmark = trusted.
    private func wifiMenu(_ cfg: Config) -> NSMenu {
        let m = NSMenu()
        var names = knownWifiNetworks()
        for s in cfg.trustedSSIDs where !names.contains(s) { names.append(s) }
        if let cur = ssid, !names.contains(cur) { names.insert(cur, at: 0) }
        if !locationOK {
            let it = m.addItem(withTitle: "Разрешите геолокацию для VPN Guard, чтобы узнавать сеть…", action: #selector(openLocationSettings), keyEquivalent: "")
            it.target = self
            m.addItem(.separator())
        }
        if names.isEmpty { m.addItem(withTitle: "Нет известных сетей", action: nil, keyEquivalent: "").isEnabled = false }
        for n in names {
            let it = m.addItem(withTitle: n, action: #selector(toggleWifi(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = n
            it.state = cfg.trustedSSIDs.contains(n) ? .on : .off
        }
        return m
    }

    private func knownWifiNetworks() -> [String] {
        func run(_ args: [String]) -> String {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = args
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }
        var dev: String?
        var isWifi = false
        for line in run(["-listallhardwareports"]).split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") { isWifi = line.contains("Wi-Fi") }
            else if isWifi, line.hasPrefix("Device:") { dev = line.dropFirst(7).trimmingCharacters(in: .whitespaces); break }
        }
        guard let dev else { return [] }
        return run(["-listpreferredwirelessnetworks", dev]).split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @objc private func addApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK else { return }
        modify { cfg in
            for url in panel.urls {
                let e = AppEntry(name: url.deletingPathExtension().lastPathComponent, path: url.path)
                if !cfg.apps.contains(e) { cfg.apps.append(e) }
            }
        }
    }

    @objc private func addSite() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Добавить сайт"
        alert.informativeText = "Домен (example.com) или IP-адрес. Блокируется сам домен и www."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Добавить")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let site = normalizeSite(field.stringValue) else {
            let e = NSAlert()
            e.messageText = "Некорректный адрес сайта"
            e.runModal()
            return
        }
        modify { if !$0.sites.contains(site) { $0.sites.append(site) } }
    }
}

private extension NSImage {
    func resized(_ side: CGFloat) -> NSImage {
        let img = self.copy() as! NSImage
        img.size = NSSize(width: side, height: side)
        return img
    }
}
