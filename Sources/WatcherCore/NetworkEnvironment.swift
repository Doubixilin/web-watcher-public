import Foundation
import Darwin
import SystemConfiguration
import CoreWLAN

public struct NetworkEnvironment: Codable, Sendable {
    public let capturedAt: Date
    public let primaryInterface: String?
    public let router: String?
    public let dnsServers: [String]
    public let proxySummary: String
    public let wifiInterface: String?
    public let wifiName: String?
    public let wifiNote: String
    public let wifiDetails: WiFiDetails

    public static func capture() -> Self {
        let store = SCDynamicStoreCreate(nil, "WebWatcher" as CFString, nil, nil)
        func dictionary(_ key: String) -> [String: Any] {
            guard let store else { return [:] }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
        }
        let ipv4 = dictionary("State:/Network/Global/IPv4")
        let dns = dictionary("State:/Network/Global/DNS")
        let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        var enabled: [String] = []
        // Only display endpoints, never proxy credentials or PAC URL query strings.
        for prefix in ["HTTP", "HTTPS", "SOCKS"] where (proxies[prefix + "Enable"] as? NSNumber)?.boolValue == true {
            let host = proxies[prefix + "Proxy"] as? String ?? "未知地址"
            let port = (proxies[prefix + "Port"] as? NSNumber)?.stringValue ?? "?"
            enabled.append("\(prefix) \(host):\(port)")
        }
        if (proxies["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true { enabled.append("自动代理配置") }
        if (proxies["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue == true { enabled.append("自动发现代理") }
        let wifi = WiFiDetails.capture()
        let note = wifi.name != nil ? "通过系统 Wi-Fi 接口读取。" : "当前名称未提供；可授权读取。名称不可读不能单独证明 Wi-Fi 已断开。"
        return .init(capturedAt: Date(), primaryInterface: ipv4["PrimaryInterface"] as? String,
                     router: ipv4["Router"] as? String, dnsServers: dns["ServerAddresses"] as? [String] ?? [],
                     proxySummary: enabled.isEmpty ? "未发现已启用的系统代理；仍可能经过隧道。" : enabled.joined(separator: "；"),
                     wifiInterface: wifi.interfaceName, wifiName: wifi.name, wifiNote: note, wifiDetails: wifi)
    }
}

enum AddressInterface {
    static func find(_ address: String?) -> String? {
        guard let address else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let socket = item.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(socket.pointee.sa_family)) else { continue }
            if numericAddress(socket) == address { return String(cString: item.pointee.ifa_name) }
        }
        return nil
    }
}

func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                      nil, 0, NI_NUMERICHOST) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
