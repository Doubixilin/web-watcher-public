import Foundation

struct HTTPMeasurements: Sendable {
    var dnsMS: Double?
    var connectionMS: Double?
    var tlsMS: Double?
    var responseMS: Double?
    var path = ObservedPath()
}

private final class HTTPMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value = HTTPMeasurements()
    func snapshot() -> HTTPMeasurements { lock.withLock { value } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        func duration(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start) * 1000)
        }
        var result = HTTPMeasurements()
        result.dnsMS = duration(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        // connectEnd includes TLS. Keep this as "connection establishment", never label it TCP RTT.
        result.connectionMS = duration(transaction.connectStartDate, transaction.connectEndDate)
        result.tlsMS = duration(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        result.responseMS = duration(transaction.requestStartDate, transaction.responseStartDate)
        result.path.localAddress = transaction.localAddress
        result.path.remoteAddress = transaction.remoteAddress
        result.path.localInterface = AddressInterface.find(transaction.localAddress)
        result.path.proxyConnection = transaction.isProxyConnection
        result.path.protocolName = transaction.networkProtocolName
        result.path.note = "URLSession 连接地址；代理标记为否仍不证明绕过 VPN 或隧道。对端可能是代理。"
        lock.withLock { value = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Record the configured target's response; don't silently change targets.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ?
                          .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

enum HTTPProbe {
    static func run(_ target: ProbeTarget) async -> ProbeResult {
        let date = Date(), start = ProcessInfo.processInfo.systemUptime
        guard let url = target.url, ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil else {
            return .init(target: target, startedAt: date, elapsedMS: 0, reachable: false,
                         phases: [], detail: "需要不含凭据的 HTTP 或 HTTPS 地址")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = target.timeout
        configuration.timeoutIntervalForResource = target.timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let metrics = HTTPMetrics()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: target.timeout)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request, delegate: metrics)
            let status = (response as? HTTPURLResponse)?.statusCode
            return interpret(target, date: date, elapsed: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                             status: status, metrics: metrics.snapshot(), error: nil)
        } catch {
            return interpret(target, date: date, elapsed: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                             status: nil, metrics: metrics.snapshot(), error: error as? URLError)
        }
    }

    static func interpret(_ target: ProbeTarget, date: Date = Date(), elapsed: Double,
                          status: Int?, metrics: HTTPMeasurements = .init(), error: URLError?) -> ProbeResult {
        var phases: [PhaseResult] = [
            .init(.dns, metrics.dnsMS == nil ? .unknown : .succeeded, milliseconds: metrics.dnsMS,
                  detail: metrics.dnsMS == nil ? "系统未提供；可能由代理解析或复用连接。" : "本次 HTTP 事务的系统解析时间。"),
            .init(.connection, metrics.connectionMS == nil ? .unknown : .succeeded, milliseconds: metrics.connectionMS,
                  detail: "连接建立时间可能包含 TLS 或代理握手，不是 TCP 往返延迟。")
        ]
        if target.url?.scheme == "https" {
            phases.append(.init(.tls, status != nil || metrics.tlsMS != nil ? .succeeded : .unknown,
                                milliseconds: metrics.tlsMS, detail: metrics.tlsMS == nil ? "有 HTTPS 响应时确认 TLS 成功；未提供独立握手时间。" : "TLS 握手时间。"))
        }
        let reachable = status != nil
        phases.append(.init(.http, reachable ? .succeeded : .failed, milliseconds: metrics.responseMS,
                            detail: status.map { "收到 HTTP \($0)；时间为请求开始到响应首字节。" } ?? "没有获得 HTTP 响应"))
        let errorPhase: ProbePhase?
        let message: String
        switch error?.code {
        case .cannotFindHost, .dnsLookupFailed:
            errorPhase = .dns; message = "系统解析失败"
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            errorPhase = .tls; message = "TLS 或证书验证失败；不能据此判断 Wi-Fi 上游故障。"
        case .cannotConnectToHost:
            errorPhase = .connection; message = "未能建立连接"
        case .timedOut:
            errorPhase = nil; message = "请求超时；系统未能确定失败阶段。"
        case .cancelled:
            errorPhase = nil; message = "检测已取消"
        case .notConnectedToInternet:
            errorPhase = nil; message = "系统报告当前网络路径不可用"
        default:
            errorPhase = nil; message = "请求未完成；失败阶段证据不足。"
        }
        if let errorPhase, let index = phases.firstIndex(where: { $0.phase == errorPhase }) {
            phases[index] = .init(errorPhase, .failed, detail: message)
        }
        let expected = status.map { target.expectedStatus.contains($0) }
        return .init(target: target, startedAt: date, elapsedMS: elapsed, reachable: reachable,
                     meetsExpectation: expected, statusCode: status, phases: phases, path: metrics.path,
                     detail: status.map { "收到 HTTP \($0)；预期 \(target.expectedStatus.lowerBound)–\(target.expectedStatus.upperBound)。不跟随重定向，不代表已登录或业务正常。" } ?? message)
    }
}
