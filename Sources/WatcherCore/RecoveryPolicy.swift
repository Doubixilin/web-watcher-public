import Foundation

public enum WiFiLinkState: String, Codable, Sendable { case associated, disconnected, poweredOff, unknown }

public struct WiFiLinkSnapshot: Codable, Sendable {
    public let interface: String?
    public let name: String?
    public let state: WiFiLinkState
    public let hasAddress: Bool
    public let rssi: Int?
    public init(interface: String?, name: String?, state: WiFiLinkState, hasAddress: Bool, rssi: Int? = nil) {
        self.interface = interface; self.name = name; self.state = state; self.hasAddress = hasAddress; self.rssi = rssi
    }
}

public struct WiFiHealth: Codable, Sendable {
    public let successes: Int
    public let failures: Int
    public let unknown: Int
    public let checks: [WiFiEndpointCheck]?
    public init(successes: Int, failures: Int, unknown: Int = 0, checks: [WiFiEndpointCheck]? = nil) {
        self.successes = successes; self.failures = failures; self.unknown = unknown
        self.checks = checks
    }
    public var allFailed: Bool { successes == 0 && failures >= 3 && unknown == 0 }
    public var verified: Bool { successes >= 2 }
}

public struct WiFiEndpointCheck: Codable, Sendable {
    public let host: String
    public let port: UInt16
    public let reachable: Bool?
    public let localInterface: String?
}

/// Monotonic times only. Unknown samples, gaps and user changes never count as failures.
public struct RecoveryPolicy: Sendable {
    public private(set) var failures = 0
    public private(set) var holdUntil: TimeInterval = 0
    private var downSince: TimeInterval?
    private var lastSample: TimeInterval?
    private var interface: String?
    private var name: String?
    public init() {}

    public mutating func reset(holdingUntil: TimeInterval = 0) {
        failures = 0; downSince = nil; lastSample = nil; holdUntil = holdingUntil
    }
    public mutating func observe(_ snapshot: WiFiLinkSnapshot, now: TimeInterval) -> Bool {
        if let lastSample, now - lastSample > 10 { reset(holdingUntil: now + 15) }
        lastSample = now
        if interface != snapshot.interface {
            interface = snapshot.interface; name = snapshot.name; reset(holdingUntil: max(holdUntil, now + 5))
            lastSample = now
        }
        if let newName = snapshot.name, let name, newName != name {
            reset(holdingUntil: max(holdUntil, now + 60))
        }
        if let newName = snapshot.name { name = newName }
        guard snapshot.state == .disconnected else {
            downSince = nil
            if snapshot.state != .associated { failures = 0 }
            return false
        }
        if downSince == nil { downSince = now }
        return now >= holdUntil && now - (downSince ?? now) >= 3
    }
    public mutating func consume(_ health: WiFiHealth, now: TimeInterval) -> Bool {
        if health.allFailed { failures += 1 } else { failures = 0 }
        return failures >= 2 && now >= holdUntil
    }
    public static func candidates(primary: String, backups: [String], current: String?, saved: [String]) -> [String] {
        var seen = Set<String>()
        return (backups + [primary]).filter {
            !$0.isEmpty && $0 != current && saved.contains($0) && seen.insert($0).inserted
                && $0.utf8.count <= 32 && !$0.contains("\n") && !$0.contains("\0")
        }
    }
}

public struct RecoveryEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let kind: String
    public let message: String
    public let wifi: WiFiLinkSnapshot?
    public let health: WiFiHealth?
    public init(kind: String, message: String, wifi: WiFiLinkSnapshot? = nil, health: WiFiHealth? = nil) {
        id = UUID(); date = Date(); self.kind = kind; self.message = message; self.wifi = wifi; self.health = health
    }
}

@MainActor
public final class RecoveryJournal {
    public private(set) var events: [RecoveryEvent] = []
    public private(set) var error: String?
    public let url: URL
    public init(url: URL) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 4_194_304 else { error = "历史文件过大，暂不读取。"; return }
                events = Array(try JSONDecoder().decode([RecoveryEvent].self, from: Data(contentsOf: url)).suffix(500))
            }
        } catch { self.error = "历史读取失败；旧文件保留，本次只在内存记录。" }
    }
    public func append(_ event: RecoveryEvent) {
        events.append(event); if events.count > 500 { events.removeFirst(events.count - 500) }
        guard error == nil else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(events).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { self.error = "历史保存失败；自动恢复已停止，请检查本机存储。" }
    }
}
