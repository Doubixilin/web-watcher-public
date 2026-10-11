import Foundation
import Darwin
import SystemConfiguration

public struct InterfaceCounters: Sendable {
    public let name: String
    public let received: UInt64
    public let sent: UInt64
    public let monotonicTime: TimeInterval
    public let date: Date
    public init(name: String, received: UInt64, sent: UInt64, monotonicTime: TimeInterval, date: Date = .now) {
        self.name = name; self.received = received; self.sent = sent; self.monotonicTime = monotonicTime; self.date = date
    }
}

public struct TrafficPoint: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let download: Double
    public let upload: Double
    public init(date: Date, download: Double, upload: Double) { self.date = date; self.download = download; self.upload = upload }
}

public struct TrafficCalculator: Sendable {
    private var previous: InterfaceCounters?
    public init() {}
    public mutating func reset() { previous = nil }
    public mutating func consume(_ sample: InterfaceCounters?) -> TrafficPoint? {
        guard let sample else { reset(); return nil }
        defer { previous = sample }
        guard let previous, previous.name == sample.name,
              sample.received >= previous.received, sample.sent >= previous.sent else { return nil }
        let elapsed = sample.monotonicTime - previous.monotonicTime
        // Wake-up and counter resets start a new baseline, rather than showing stale average traffic.
        guard elapsed > 0, elapsed <= 10 else { return nil }
        return .init(date: sample.date, download: Double(sample.received - previous.received) / elapsed,
                     upload: Double(sample.sent - previous.sent) / elapsed)
    }
}

public enum TrafficFormat {
    public static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes < 1024 { return String(format: "%.0f B/s", bytes) }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB/s", bytes / 1024) }
        return String(format: "%.2f MB/s", bytes / (1024 * 1024))
    }
}

public struct InterfaceOption: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let label: String
}

public enum InterfaceTraffic {
    public static func interfaces() -> [InterfaceOption] {
        let all = SCNetworkInterfaceCopyAll() as NSArray
        return all.compactMap { item -> InterfaceOption? in
            let network = item as! SCNetworkInterface
            guard let name = SCNetworkInterfaceGetBSDName(network) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(network) as String?,
                  type == kSCNetworkInterfaceTypeIEEE80211 as String || type == kSCNetworkInterfaceTypeEthernet as String else { return nil }
            return .init(name: name, label: "\(SCNetworkInterfaceGetLocalizedDisplayName(network) as String? ?? name) · \(name)")
        }.sorted { $0.name < $1.name }
    }

    public static func automaticInterface() -> String? {
        let allowed = Set(interfaces().map(\.name))
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] ?? [:]
        if let name = global["PrimaryInterface"] as? String, allowed.contains(name), hasAddress(name) { return name }
        // A VPN can own the default route; use the first configured active physical service, not utun/lo0 totals.
        let setup = SCDynamicStoreCopyValue(nil, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any] ?? [:]
        for service in setup["ServiceOrder"] as? [String] ?? [] {
            let state = SCDynamicStoreCopyValue(nil, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any] ?? [:]
            if let name = state["InterfaceName"] as? String, allowed.contains(name), state["Router"] != nil, hasAddress(name) { return name }
        }
        return allowed.sorted().first(where: hasAddress)
    }

    private static func hasAddress(_ name: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            if String(cString: item.pointee.ifa_name) == name,
               Int32(item.pointee.ifa_flags) & IFF_UP != 0,
               let address = item.pointee.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) { return true }
        }
        return false
    }

    public static func read(_ name: String) -> InterfaceCounters? {
        let index = if_nametoindex(name)
        guard index > 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size: size_t = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= size {
            let header = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self) }
            guard header.ifm_msglen > 0 else { return nil }
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
                let value = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self) }
                if UInt32(value.ifm_index) == index {
                    return .init(name: name, received: value.ifm_data.ifi_ibytes, sent: value.ifm_data.ifi_obytes,
                                 monotonicTime: ProcessInfo.processInfo.systemUptime)
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return nil
    }
}
