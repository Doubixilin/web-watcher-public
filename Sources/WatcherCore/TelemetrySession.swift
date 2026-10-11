import Foundation
import Combine

@MainActor
public final class TelemetrySession: ObservableObject {
    @Published public private(set) var wifi = WiFiDetails.capture()
    @Published public private(set) var interfaceName: String?
    @Published public private(set) var latest: TrafficPoint?
    @Published public private(set) var history: [TrafficPoint] = []
    @Published public private(set) var interfaces: [InterfaceOption] = []
    @Published public private(set) var savedNetworks: [String] = []
    @Published public private(set) var nearby: [NearbyWiFi] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var scanMessage = "附近网络尚未扫描"
    public var preferredInterface: String = "" { didSet { if preferredInterface != oldValue { calculator.reset(); latest = nil; history = [] } } }
    private var calculator = TrafficCalculator()
    private var task: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var lastDetailsRefresh: TimeInterval = 0

    public init() {}
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sample()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    public func stop() { task?.cancel(); task = nil; calculator.reset(); latest = nil }
    public func refreshDetails() { lastDetailsRefresh = 0 }

    private func sample() async {
        let refresh = ProcessInfo.processInfo.systemUptime - lastDetailsRefresh >= 10
        let preferred = preferredInterface
        let previousName = interfaceName
        let snapshot = await Task.detached(priority: .utility) {
            let name = preferred.isEmpty ? (refresh ? InterfaceTraffic.automaticInterface() : previousName) : preferred
            return (name, name.flatMap(InterfaceTraffic.read), refresh ? WiFiDetails.capture() : nil,
                    refresh ? InterfaceTraffic.interfaces() : nil, refresh ? WiFiCatalog.savedNames() : nil)
        }.value
        guard !Task.isCancelled, preferred == preferredInterface else { return }
        if snapshot.0 != interfaceName { history = [] }
        interfaceName = snapshot.0
        latest = calculator.consume(snapshot.1)
        if let latest { history.append(latest); if history.count > 180 { history.removeFirst(history.count - 180) } }
        if let wifi = snapshot.2 { self.wifi = wifi }
        if let interfaces = snapshot.3 { self.interfaces = interfaces }
        if let names = snapshot.4 { savedNetworks = names; lastDetailsRefresh = ProcessInfo.processInfo.systemUptime }
    }

    public func scanNearby() {
        guard scanTask == nil else { return }
        isScanning = true; scanMessage = "正在读取附近网络…"
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try WiFiCatalog.scan() } }.value
            guard let self else { return }
            defer { self.isScanning = false; self.scanTask = nil }
            switch result {
            case .success(let networks):
                self.nearby = networks
                self.scanMessage = networks.isEmpty ? "未获得可显示的网络；请核对定位授权与 Wi-Fi 状态。" : "已更新附近网络；可见不代表公网可用。"
            case .failure:
                self.scanMessage = "扫描未完成；请稍后重试并核对定位授权。"
            }
        }
    }
}
