import Foundation
import CoreWLAN
import SystemConfiguration
import Darwin

public protocol WiFiRecoveryAdapting: Sendable {
    func snapshot() async -> WiFiLinkSnapshot
    func savedNames() async -> [String]
    func health(interface: String) async -> WiFiHealth
    func connect(interface: String, name: String) async -> String?
    func websiteReachable() async -> Bool
}

public struct SystemWiFiRecoveryAdapter: WiFiRecoveryAdapting {
    public init() {}
    public func snapshot() async -> WiFiLinkSnapshot {
        await Task.detached(priority: .utility) { Self.capture() }.value
    }
    public func savedNames() async -> [String] {
        await Task.detached(priority: .utility) { WiFiCatalog.savedNames() }.value
    }
    public static func capture() -> WiFiLinkSnapshot {
        guard let wifi = CWWiFiClient.shared().interface(), let interface = wifi.interfaceName else {
            return .init(interface: nil, name: nil, state: .unknown, hasAddress: false)
        }
        let store = SCDynamicStoreCreate(nil, "WebWatcherRecovery" as CFString, nil, nil)
        let link = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Interface/\(interface)/Link" as CFString) } as? [String: Any]
        let active = (link?["Active"] as? NSNumber)?.boolValue
        let powered = wifi.powerOn()
        let phy = wifi.activePHYMode().rawValue
        let name = wifi.ssid()
        let state: WiFiLinkState
        if powered && active == true && phy > 0 { state = .associated }
        else if powered && active == false && phy == 0 { state = .disconnected }
        else if !powered && active == false { state = .poweredOff }
        else { state = .unknown }
        var list: UnsafeMutablePointer<ifaddrs>?
        var hasAddress = false
        if getifaddrs(&list) == 0 {
            defer { if let list { freeifaddrs(list) } }
            var cursor = list
            while let item = cursor {
                defer { cursor = item.pointee.ifa_next }
                guard String(cString: item.pointee.ifa_name) == interface,
                      let address = item.pointee.ifa_addr,
                      [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)),
                      let value = numericAddress(address),
                      !value.hasPrefix("169.254."), !value.hasPrefix("fe80:"), value != "0.0.0.0", value != "::" else { continue }
                hasAddress = true
            }
        }
        let rssi = wifi.rssiValue()
        return .init(interface: interface, name: name, state: state, hasAddress: hasAddress,
                     rssi: (-127..<0).contains(rssi) ? rssi : nil)
    }
    public func health(interface: String) async -> WiFiHealth {
        // Numeric destinations avoid proxy-provided synthetic DNS. Three separate operators.
        let hosts = ["223.5.5.5", "119.29.29.29", "1.1.1.1"]
        return await withTaskGroup(of: WiFiEndpointCheck.self) { group in
            for host in hosts {
                group.addTask {
                    let target = ProbeTarget(id: host, name: host, kind: .tcp, host: host, port: 53, timeout: 3)
                    let result = await TCPProbe.runOnWiFi(target, interface: interface)
                    let reachable: Bool? = Task.isCancelled || result.detail == "无线绑定未核实" ? nil : result.reachable
                    return .init(host: host, port: 53, reachable: reachable, localInterface: result.path.localInterface)
                }
            }
            var successes = 0, failures = 0, unknown = 0
            var checks: [WiFiEndpointCheck] = []
            for await value in group {
                checks.append(value)
                if value.reachable == true { successes += 1 } else if value.reachable == false { failures += 1 } else { unknown += 1 }
            }
            return .init(successes: successes, failures: failures, unknown: unknown, checks: checks.sorted { $0.host < $1.host })
        }
    }
    public func connect(interface: String, name: String) async -> String? {
        // Ask the system tool to join a saved network. Never read/pass a password or invoke sudo.
        do {
            let result = try await BoundedCommand.run(executable: "/usr/sbin/networksetup",
                arguments: ["-setairportnetwork", interface, name], timeout: 15, outputLimit: 4096)
            if result.cancelled { return "连接已取消；系统已受理的请求仍需观察实际状态。" }
            if result.timedOut { return "系统连接请求超时。" }
            let output = result.text.lowercased()
            if result.status != 0 || ["error", "failed", "could not", "not find", "not found", "password"].contains(where: output.contains) {
                return "系统未完成连接；请确认网络可见、已保存凭据及切网权限。"
            }
            return nil // A successful command is only a request, never connectivity proof.
        } catch { return "无法发起系统连接请求。" }
    }
    public func websiteReachable() async -> Bool {
        for target in ProbeTarget.defaults where target.kind == .http {
            if Task.isCancelled { return false }
            if await SystemProbeRunner().probe(target).reachable { return true }
        }
        return false
    }
}

@MainActor
public final class WiFiEventObserver: NSObject, CWEventDelegate {
    private let client = CWWiFiClient()
    public var onChange: (() -> Void)?
    public func start() -> Bool {
        client.delegate = self
        do {
            for type: CWEventType in [.linkDidChange, .ssidDidChange, .powerDidChange] { try client.startMonitoringEvent(with: type) }
            return true
        } catch { return false }
    }
    public func stop() { try? client.stopMonitoringAllEvents(); client.delegate = nil }
    nonisolated public func linkDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    nonisolated public func ssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    nonisolated public func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    nonisolated private func changed() { Task { @MainActor [weak self] in self?.onChange?() } }
}
