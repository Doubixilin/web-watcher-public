import AppKit
import SwiftUI
import Combine
import WatcherCore

@main
struct WebWatcherMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--recovery-check") {
            let adapter = SystemWiFiRecoveryAdapter()
            let snapshot = await adapter.snapshot()
            let health = if let interface = snapshot.interface, snapshot.state == .associated, snapshot.hasAddress {
                await adapter.health(interface: interface)
            } else { WiFiHealth(successes: 0, failures: 0, unknown: 3) }
            struct Check: Encodable { let wifi: WiFiLinkSnapshot; let health: WiFiHealth }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(Check(wifi: snapshot, health: health)) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        if CommandLine.arguments.contains("--probe-once") {
            var results: [ProbeResult] = []
            for target in ProbeTarget.defaults { results.append(await SystemProbeRunner().probe(target)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(results) { print(String(decoding: data, as: UTF8.self)) }
            return
        }
        runApplication()
    }

    @MainActor
    static func runApplication() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = MonitorSession()
    let telemetry = TelemetrySession()
    let preferences = AppPreferences()
    let authorization = WiFiAuthorization()
    let processes = ProcessTrafficSession()
    let recovery = RecoverySession()
    let wifiEvents = WiFiEventObserver()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var subscriptions = Set<AnyCancellable>()
    let summaryItem = NSMenuItem(title: "等待检测", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "暂停监测", action: #selector(toggleMonitoring), keyEquivalent: "")
    let recoveryItem = NSMenuItem(title: "自动恢复未开启", action: nil, keyEquivalent: "")
    var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(summaryItem)
        menu.addItem(recoveryItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开 Web Watcher", action: #selector(showWindow), keyEquivalent: "o")
        open.target = self; menu.addItem(open)
        let check = NSMenuItem(title: "立即检测", action: #selector(checkNow), keyEquivalent: "")
        check.target = self; menu.addItem(check)
        pauseItem.target = self; menu.addItem(pauseItem)
        let display = NSMenuItem(title: "网速显示", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for mode in MenuDisplay.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMenuDisplay(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue
            displayMenu.addItem(item)
        }
        display.submenu = displayMenu; menu.addItem(display)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Web Watcher", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem?.menu = menu
        monitor.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.refreshMenu() }
        }.store(in: &subscriptions)
        telemetry.objectWillChange.sink { [weak self] in Task { @MainActor in self?.refreshMenu() } }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.telemetry.preferredInterface = self.preferences.interfaceName
                self.configureRecovery()
                self.refreshMenu()
            }
        }.store(in: &subscriptions)
        monitor.$isRunning.sink { [weak self] _ in Task { @MainActor in self?.configureRecovery() } }.store(in: &subscriptions)
        recovery.objectWillChange.sink { [weak self] in Task { @MainActor in self?.refreshMenu() } }.store(in: &subscriptions)
        authorization.onChange = { [weak self] in self?.telemetry.refreshDetails(); self?.configureRecovery() }
        recovery.onNetworkChange = { [weak self] in
            guard let self else { return }
            self.telemetry.refreshDetails()
            if self.monitor.isRunning { self.monitor.checkNow() }
        }
        wifiEvents.onChange = { [weak self] in self?.recovery.signalChange() }
        if !wifiEvents.start() { recovery.recordObserverFallback() }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.recovery.suspend() } }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.recovery.resume() } }.store(in: &subscriptions)
        telemetry.preferredInterface = preferences.interfaceName
        telemetry.start()
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "持续观察本机网络")
        #if DEBUG
        monitor.$completedRounds.dropFirst().sink { [weak self] count in
            Task { @MainActor in
                guard let self, count > 0 else { return }
                print("[Web Watcher] 第 \(count) 轮完成：\(self.monitor.assessment.title)")
                fflush(stdout)
            }
        }.store(in: &subscriptions)
        #endif
        refreshMenu()
        showWindow()
        monitor.start()
        configureRecovery(); recovery.start()
    }

    func configureRecovery() {
        recovery.configure(enabled: preferences.autoRecovery, monitoring: monitor.isRunning,
                           authorized: authorization.isAuthorized, primary: preferences.primaryWiFi, backups: preferences.backupWiFi)
    }

    func refreshMenu() {
        let title = monitor.isRunning ? monitor.assessment.title : "网站监测已暂停"
        summaryItem.title = title
        recoveryItem.title = recovery.title
        pauseItem.title = monitor.isRunning ? "暂停网站监测" : "继续网站监测"
        let symbol = monitor.isRunning ? (monitor.results.contains { !$0.reachable || $0.meetsExpectation == false } ? "network.badge.shield.half.filled" : "network") : "pause.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(systemSymbolName: "network", accessibilityDescription: title)
        switch preferences.menuDisplay {
        case .icon: statusItem?.button?.title = ""
        case .download: statusItem?.button?.title = " ↓ \(TrafficFormat.rate(telemetry.latest?.download))"
        case .upload: statusItem?.button?.title = " ↑ \(TrafficFormat.rate(telemetry.latest?.upload))"
        case .both: statusItem?.button?.title = " ↓ \(TrafficFormat.rate(telemetry.latest?.download))  ↑ \(TrafficFormat.rate(telemetry.latest?.upload))"
        }
        statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem?.button?.toolTip = "\(title) · 流量接口 \(telemetry.interfaceName ?? "未知")"
        for item in statusItem?.menu?.items.first(where: { $0.submenu != nil })?.submenu?.items ?? [] {
            item.state = item.representedObject as? String == preferences.menuDisplay.rawValue ? .on : .off
        }
    }

    @objc func showWindow() {
        if window == nil {
            let view = Dashboard(monitor: monitor, telemetry: telemetry, preferences: preferences, authorization: authorization, processes: processes, recovery: recovery)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Web Watcher"
            window.delegate = self
            window.contentView = NSHostingView(rootView: view)
            window.minSize = NSSize(width: 1000, height: 640)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func checkNow() { monitor.checkNow() }
    @objc func selectMenuDisplay(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = MenuDisplay(rawValue: raw) { preferences.menuDisplay = mode }
    }
    @objc func toggleMonitoring() { monitor.isRunning ? monitor.pause() : monitor.start() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func windowWillClose(_ notification: Notification) { processes.stop() }
    func applicationWillTerminate(_ notification: Notification) {
        monitor.pause(); telemetry.stop(); processes.stop(); recovery.stop(); wifiEvents.stop()
        BoundedCommand.stopAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}
