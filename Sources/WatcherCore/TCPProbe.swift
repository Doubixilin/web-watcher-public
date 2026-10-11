import Foundation
import Network

// Mutable state is confined to queue; cancellation enters the same queue.
private final class TCPAttempt: @unchecked Sendable {
    let queue = DispatchQueue(label: "WebWatcher.TCP")
    let target: ProbeTarget
    let connection: NWConnection
    let startedAt = Date()
    let start = ProcessInfo.processInfo.systemUptime
    var continuation: CheckedContinuation<ProbeResult, Never>?
    var deadline: DispatchWorkItem?
    var cancelled = false
    let wifiInterface: String?

    init(_ target: ProbeTarget, wifiInterface: String? = nil) {
        self.target = target
        self.wifiInterface = wifiInterface
        let parameters = NWParameters.tcp
        if wifiInterface != nil { parameters.requiredInterfaceType = .wifi }
        connection = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port)!, using: parameters)
    }

    func run() async -> ProbeResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    guard !self.cancelled else { self.finish(false, "检测已取消"); return }
                    self.connection.stateUpdateHandler = { [self] state in
                        switch state {
                        case .ready: finish(true, "TCP 连接已建立；未检测 TLS 或网站业务。")
                        case .failed: finish(false, "TCP 连接未能建立")
                        default: break // .waiting can recover; keep the bounded deadline.
                        }
                    }
                    let timeout = DispatchWorkItem { [self] in finish(false, "TCP 连接超时（包含系统解析等待）") }
                    self.deadline = timeout
                    self.queue.asyncAfter(deadline: .now() + self.target.timeout, execute: timeout)
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: {
            self.queue.async { self.cancelled = true; self.finish(false, "检测已取消") }
        }
    }

    func finish(_ success: Bool, _ detail: String) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        var path = ObservedPath()
        if case let .hostPort(host, _) = connection.currentPath?.localEndpoint { path.localAddress = "\(host)" }
        if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint { path.remoteAddress = "\(host)" }
        path.localInterface = AddressInterface.find(path.localAddress)
        let verifiedSuccess = success && (wifiInterface == nil || (path.localInterface == wifiInterface && connection.currentPath?.usesInterfaceType(.wifi) == true))
        path.protocolName = "TCP"
        path.configured = wifiInterface.map { "绑定 Wi-Fi 类型 · 核对接口 \($0)" } ?? "系统默认"
        path.note = wifiInterface == nil ? "Network.framework 系统路由；不使用 HTTP 代理配置，仍可能经过 VPN 或隧道。" : "数字 IP、要求 Wi-Fi 接口；成功时核对本地地址对应接口。"
        connection.stateUpdateHandler = nil
        connection.cancel()
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        continuation.resume(returning: .init(target: target, startedAt: startedAt, elapsedMS: elapsed,
            reachable: verifiedSuccess, phases: [.init(.connection, verifiedSuccess ? .succeeded : .failed, milliseconds: elapsed,
            detail: "包含系统解析和连接等待，不是单独的 TCP 握手时间。")], path: path,
            detail: wifiInterface != nil && ((success && !verifiedSuccess) || (path.localInterface != nil && path.localInterface != wifiInterface)) ? "无线绑定未核实" : detail))
    }
}

enum TCPProbe {
    static func run(_ target: ProbeTarget) async -> ProbeResult { await TCPAttempt(target).run() }
    static func runOnWiFi(_ target: ProbeTarget, interface: String) async -> ProbeResult { await TCPAttempt(target, wifiInterface: interface).run() }
}
