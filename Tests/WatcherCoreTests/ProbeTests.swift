import XCTest
import Foundation
import Network
@testable import WatcherCore

final class ProbeTests: XCTestCase, @unchecked Sendable {
    let target = ProbeTarget(id: "test", name: "测试", kind: .http, host: "localhost", url: URL(string: "https://localhost/"))

    func testHTTPErrorIsReachableButDoesNotMeetExpectation() {
        for code in [404, 422, 500, 501] {
            let result = HTTPProbe.interpret(target, elapsed: 10, status: code, error: nil)
            XCTAssertTrue(result.reachable)
            XCTAssertEqual(result.meetsExpectation, false)
            XCTAssertEqual(result.phases.first { $0.phase == .http }?.status, .succeeded)
            XCTAssertEqual(result.phases.first { $0.phase == .tls }?.status, .succeeded)
            XCTAssertEqual(RoundAssessment.evaluate([result]).title, "目标可达 · 部分响应未达预期")
        }
    }

    func testUnknownTimingsStayUnknown() {
        let result = HTTPProbe.interpret(target, elapsed: 100, status: 200, error: nil)
        XCTAssertNil(result.phases.first { $0.phase == .dns }?.milliseconds)
        XCTAssertEqual(result.phases.first { $0.phase == .dns }?.status, .unknown)
        XCTAssertNil(result.phases.first { $0.phase == .connection }?.milliseconds)
        XCTAssertNil(result.phases.first { $0.phase == .http }?.milliseconds)
        XCTAssertNil(result.path.proxyConnection)
    }

    func testTLSFailureDoesNotBecomeDNSFailure() {
        let result = HTTPProbe.interpret(target, elapsed: 100, status: nil, error: URLError(.serverCertificateUntrusted))
        XCTAssertFalse(result.reachable)
        XCTAssertEqual(result.phases.first { $0.phase == .tls }?.status, .failed)
        XCTAssertEqual(result.phases.first { $0.phase == .dns }?.status, .unknown)
        XCTAssertNil(result.meetsExpectation)
    }

    func testTimeoutDoesNotInventFailedLayerOrRootCause() {
        let result = HTTPProbe.interpret(target, elapsed: 100, status: nil, error: URLError(.timedOut))
        XCTAssertEqual(result.phases.first { $0.phase == .connection }?.status, .unknown)
        XCTAssertTrue(RoundAssessment.evaluate([result]).detail.contains("证据不足"))
    }

    func testSingleTargetFailureWithReachablePeerIsPartial() {
        let good = HTTPProbe.interpret(target, elapsed: 10, status: 200, error: nil)
        let bad = HTTPProbe.interpret(target, elapsed: 10, status: nil, error: URLError(.dnsLookupFailed))
        XCTAssertEqual(RoundAssessment.evaluate([good, bad]).title, "部分探测未成功")
        XCTAssertEqual(bad.phases.first { $0.phase == .dns }?.status, .failed)
    }

    func testCustomExpectedStatusDoesNotChangeReachability() {
        let expected422 = ProbeTarget(id: "422", name: "测试", kind: .http, host: "localhost", url: target.url, expectedStatus: 422...422)
        let result = HTTPProbe.interpret(expected422, elapsed: 10, status: 422, error: nil)
        XCTAssertTrue(result.reachable)
        XCTAssertEqual(result.meetsExpectation, true)
    }

    func testActualHTTP422AndRedirectWithoutFollowing() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        for (path, expected) in [("/422", 422), ("/redirect", 302)] {
            let result = await SystemProbeRunner().probe(server.target(path))
            XCTAssertEqual(result.statusCode, expected, result.detail)
            XCTAssertTrue(result.reachable)
            XCTAssertEqual(result.path.localAddress, "127.0.0.1")
            XCTAssertEqual(result.path.localInterface, "lo0")
            XCTAssertEqual(result.meetsExpectation, expected == 302)
        }
    }

    func testActualHTTPTimeoutIsBounded() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let result = await SystemProbeRunner().probe(server.target("/slow", timeout: 0.2))
        XCTAssertFalse(result.reachable)
        XCTAssertNil(result.statusCode)
        XCTAssertTrue(result.detail.contains("超时"), result.detail)
        XCTAssertLessThan(result.elapsedMS, 2000)
    }

    func testActualTCPConnectionAndClosedPort() async throws {
        let server = try LocalHTTPServer()
        let port = server.port
        let target = ProbeTarget(id: "tcp", name: "TCP", kind: .tcp, host: "127.0.0.1", port: port, timeout: 0.5)
        let good = await SystemProbeRunner().probe(target)
        XCTAssertTrue(good.reachable, good.detail)
        XCTAssertEqual(good.path.localInterface, "lo0")
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        let bad = await SystemProbeRunner().probe(target)
        XCTAssertFalse(bad.reachable)
        XCTAssertLessThan(bad.elapsedMS, 2000)
    }

    func testActualSystemDNSAndCancellation() async {
        let dns = ProbeTarget(id: "dns", name: "DNS", kind: .dns, host: "localhost", timeout: 1)
        let result = await SystemProbeRunner().probe(dns)
        XCTAssertTrue(result.reachable)
        XCTAssertEqual(result.phases.count, 1)
        XCTAssertNil(result.path.localAddress)
        let cancelled = Task { await SystemProbeRunner().probe(.init(id: "invalid", name: "DNS", kind: .dns, host: "no-such-host.invalid", timeout: 5)) }
        cancelled.cancel()
        let failed = await cancelled.value
        XCTAssertFalse(failed.reachable)
        XCTAssertLessThan(failed.elapsedMS, 1000)
    }
}

// Loopback-only fixture; no changes to Wi-Fi, DNS, proxies or external services.
private final class LocalHTTPServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "WebWatcher.TestHTTP")
    var port: UInt16 { listener.port!.rawValue }
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, listener.port != nil else {
            listener.cancel(); throw URLError(.cannotConnectToHost)
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] incoming, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = data
            if let incoming { accumulated.append(incoming) }
            let request = String(decoding: accumulated, as: UTF8.self)
            if request.contains("\r\n\r\n") {
                if request.contains("/slow") { return }
                let redirect = request.contains("/redirect")
                let response = "HTTP/1.1 \(redirect ? "302 Found" : "422 Unprocessable Entity")\r\n\(redirect ? "Location: /422\r\n" : "")Content-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if !complete && error == nil && accumulated.count < 8192 {
                self.receive(connection, data: accumulated)
            } else { connection.cancel() }
        }
    }

    func target(_ path: String, timeout: TimeInterval = 1) -> ProbeTarget {
        .init(id: path, name: "本地测试", kind: .http, host: "127.0.0.1", port: port,
              url: URL(string: "http://127.0.0.1:\(port)\(path)"), timeout: timeout)
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
