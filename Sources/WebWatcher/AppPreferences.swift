import Foundation
import AppKit
import CoreLocation
import Combine
import WatcherCore

enum MenuDisplay: String, CaseIterable, Identifiable {
    case icon, download, upload, both
    var id: String { rawValue }
    var title: String {
        switch self { case .icon: "仅图标"; case .download: "下载速率"; case .upload: "上传速率"; case .both: "上下行速率" }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var menuDisplay: MenuDisplay { didSet { defaults.set(menuDisplay.rawValue, forKey: "menuDisplay") } }
    @Published var interfaceName: String { didSet { defaults.set(interfaceName, forKey: "trafficInterface") } }
    @Published var primaryWiFi: String { didSet { defaults.set(primaryWiFi, forKey: "primaryWiFi") } }
    @Published var backupWiFi: [String] { didSet { defaults.set(backupWiFi, forKey: "backupWiFi") } }
    @Published var autoRecovery: Bool { didSet { defaults.set(autoRecovery, forKey: "autoRecovery") } }
    init() {
        menuDisplay = MenuDisplay(rawValue: defaults.string(forKey: "menuDisplay") ?? "both") ?? .both
        interfaceName = defaults.string(forKey: "trafficInterface") ?? ""
        primaryWiFi = defaults.string(forKey: "primaryWiFi") ?? ""
        backupWiFi = defaults.stringArray(forKey: "backupWiFi") ?? []
        autoRecovery = defaults.bool(forKey: "autoRecovery")
    }
    func setBackup(_ name: String, enabled: Bool) {
        backupWiFi.removeAll { $0 == name }
        if enabled { backupWiFi.append(name) }
    }
}

@MainActor
final class WiFiAuthorization: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    var onChange: (() -> Void)?
    var isAuthorized: Bool { status == .authorizedAlways }
    var message: String {
        guard CLLocationManager.locationServicesEnabled() else { return "系统定位服务已关闭；开启后可读取 Wi-Fi 名称。" }
        switch status {
        case .authorizedAlways: return "已获系统授权；仅读取 Wi-Fi 信息，不采集位置坐标。"
        case .denied, .restricted: return "Wi-Fi 名称访问受限，可在系统设置中调整定位权限。"
        default: return "macOS 要求定位授权才能读取 Wi-Fi 名称；公网探测和流量统计不需要此权限。"
        }
    }
    override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }
    func request() {
        if !CLLocationManager.locationServicesEnabled() || status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        } else if status == .notDetermined { manager.requestAlwaysAuthorization() }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = self.manager.authorizationStatus
            self.onChange?()
        }
    }
}
