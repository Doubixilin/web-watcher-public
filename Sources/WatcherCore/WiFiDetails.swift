import Foundation
import CoreWLAN

public struct WiFiDetails: Codable, Sendable {
    public let name: String?
    public let interfaceName: String?
    public let rssi: Int?
    public let noise: Int?
    public let phyMode: Int
    public let channel: Int?
    public let bandGHz: Int?
    public let channelWidthMHz: Int?
    public let transmitMbps: Double?

    public init(name: String?, interfaceName: String?, rssi: Int?, noise: Int?, phyMode: Int,
                channel: Int? = nil, bandGHz: Int? = nil, channelWidthMHz: Int? = nil, transmitMbps: Double? = nil) {
        self.name = name; self.interfaceName = interfaceName
        self.rssi = rssi.flatMap { (-127..<0).contains($0) ? $0 : nil }
        self.noise = noise.flatMap { (-127..<0).contains($0) ? $0 : nil }
        self.phyMode = phyMode; self.channel = channel; self.bandGHz = bandGHz
        self.channelWidthMHz = channelWidthMHz
        self.transmitMbps = transmitMbps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public var signalToNoise: Int? {
        guard let rssi, let noise else { return nil }
        return rssi - noise
    }
    public var generation: String {
        switch phyMode {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "Wi-Fi 4"
        case 5: "Wi-Fi 5"
        case 6: bandGHz == 6 ? "Wi-Fi 6E" : "Wi-Fi 6"
        case 7: "Wi-Fi 7"
        default: "协议未知"
        }
    }
    public var protocolName: String {
        [1: "802.11a", 2: "802.11b", 3: "802.11g", 4: "802.11n", 5: "802.11ac", 6: "802.11ax", 7: "802.11be"][phyMode] ?? "未知"
    }
    public var signalLevel: Int {
        guard let rssi else { return 0 }
        switch rssi { case (-55)...: return 4; case (-67)...: return 3; case (-75)...: return 2; default: return 1 }
    }
    public var signalLabel: String {
        switch signalLevel { case 4: "信号很强"; case 3: "信号良好"; case 2: "信号一般"; case 1: "信号偏弱"; default: "信号未提供" }
    }

    public static func capture() -> Self {
        guard let wifi = CWWiFiClient.shared().interface() else {
            return .init(name: nil, interfaceName: nil, rssi: nil, noise: nil, phyMode: 0)
        }
        let channel = wifi.wlanChannel()
        let band: Int? = switch channel?.channelBand.rawValue { case 1: 2; case 2: 5; case 3: 6; default: nil }
        let width: Int? = switch channel?.channelWidth.rawValue { case 1: 20; case 2: 40; case 3: 80; case 4: 160; default: nil }
        return .init(name: wifi.ssid(), interfaceName: wifi.interfaceName, rssi: wifi.rssiValue(), noise: wifi.noiseMeasurement(),
                     phyMode: wifi.activePHYMode().rawValue, channel: channel.map { Int($0.channelNumber) },
                     bandGHz: band, channelWidthMHz: width, transmitMbps: wifi.transmitRate())
    }
}

public struct NearbyWiFi: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let rssi: Int
    public let capturedAt: Date
}

public enum WiFiCatalog {
    public static func savedNames() -> [String] {
        let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        return Array(Set(profiles.compactMap(\.ssid).filter { !$0.isEmpty })).sorted()
    }

    public static func scan() throws -> [NearbyWiFi] {
        guard let wifi = CWWiFiClient.shared().interface() else { return [] }
        let networks = try wifi.scanForNetworks(withName: nil, includeHidden: false)
        var strongest: [String: Int] = [:]
        for network in networks {
            guard let name = network.ssid, !name.isEmpty else { continue }
            strongest[name] = max(strongest[name] ?? -127, network.rssiValue)
        }
        return strongest.map { .init(name: $0.key, rssi: $0.value, capturedAt: Date()) }.sorted { $0.rssi > $1.rssi }
    }
}
