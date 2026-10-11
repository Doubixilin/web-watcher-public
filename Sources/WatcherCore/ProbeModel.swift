import Foundation

public enum ProbeKind: String, Codable, Sendable { case dns, tcp, http }
public enum ProbePhase: String, Codable, Sendable { case dns, connection, tls, http }
public enum PhaseStatus: String, Codable, Sendable { case succeeded, failed, unknown }

public struct ProbeTarget: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let kind: ProbeKind
    public let host: String
    public let port: UInt16
    public let url: URL?
    public let timeout: TimeInterval
    public let expectedStatus: ClosedRange<Int>

    public init(id: String, name: String, kind: ProbeKind, host: String, port: UInt16 = 443,
                url: URL? = nil, timeout: TimeInterval = 5, expectedStatus: ClosedRange<Int> = 200...399) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port
        self.url = url; self.timeout = timeout; self.expectedStatus = expectedStatus
    }

    public static let defaults: [Self] = [
        .init(id: "baidu-dns", name: "百度 · DNS", kind: .dns, host: "www.baidu.com"),
        .init(id: "qq-tcp", name: "腾讯 · TCP", kind: .tcp, host: "www.qq.com"),
        .init(id: "baidu-https", name: "百度 · HTTPS", kind: .http, host: "www.baidu.com", url: URL(string: "https://www.baidu.com/")),
        .init(id: "qq-https", name: "腾讯 · HTTPS", kind: .http, host: "www.qq.com", url: URL(string: "https://www.qq.com/"))
    ]
}

public struct PhaseResult: Codable, Sendable {
    public let phase: ProbePhase
    public let status: PhaseStatus
    public let milliseconds: Double?
    public let detail: String

    public init(_ phase: ProbePhase, _ status: PhaseStatus, milliseconds: Double? = nil, detail: String) {
        self.phase = phase; self.status = status; self.milliseconds = milliseconds; self.detail = detail
    }
}

public struct ObservedPath: Codable, Sendable {
    public var configured = "系统默认"
    public var localAddress: String?
    public var remoteAddress: String?
    public var localInterface: String?
    public var proxyConnection: Bool?
    public var protocolName: String?
    public var note = "物理出口未验证；系统代理、VPN 或隧道可能影响路径。"
    public init() {}
}

public struct ProbeResult: Identifiable, Codable, Sendable {
    public var id: String { target.id }
    public let target: ProbeTarget
    public let startedAt: Date
    public let elapsedMS: Double
    public let reachable: Bool
    public let meetsExpectation: Bool?
    public let statusCode: Int?
    public let phases: [PhaseResult]
    public let path: ObservedPath
    public let detail: String

    public init(target: ProbeTarget, startedAt: Date, elapsedMS: Double, reachable: Bool,
                meetsExpectation: Bool? = nil, statusCode: Int? = nil, phases: [PhaseResult],
                path: ObservedPath = .init(), detail: String) {
        self.target = target; self.startedAt = startedAt; self.elapsedMS = elapsedMS
        self.reachable = reachable; self.meetsExpectation = meetsExpectation; self.statusCode = statusCode
        self.phases = phases; self.path = path; self.detail = detail
    }

    public var headline: String {
        guard reachable else { return "探测未成功" }
        if meetsExpectation == false { return "服务器可达 · 响应未达预期" }
        return "探测成功"
    }
}

public struct RoundAssessment: Sendable {
    public let title: String
    public let detail: String

    public static func evaluate(_ results: [ProbeResult]) -> Self {
        guard !results.isEmpty else { return .init(title: "等待检测", detail: "尚无探测证据。") }
        let failed = results.filter { !$0.reachable }.count
        if failed == results.count {
            return .init(title: "多项探测未成功", detail: "可能涉及解析、代理或网络路径；证据不足，不能确定 Wi-Fi 上游故障。")
        }
        if failed > 0 {
            return .init(title: "部分探测未成功", detail: "已有目标可达；请查看各项证据，单个目标异常不代表出口断网。")
        }
        if results.contains(where: { $0.meetsExpectation == false }) {
            return .init(title: "目标可达 · 部分响应未达预期", detail: "HTTP 错误表示服务器已响应，需与网络故障分别观察。")
        }
        return .init(title: "当前探测均成功", detail: "仅代表这些目标在系统默认路径上的结果；物理出口和远程控制会话尚未验证。")
    }
}

public protocol ProbeRunning: Sendable {
    func probe(_ target: ProbeTarget) async -> ProbeResult
}
