import XCTest
@testable import WatcherCore

final class ProcessTrafficTests: XCTestCase, @unchecked Sendable {
    func testCSVMapsHeadersAndPreservesNamesWithDotsAndCommas() {
        let text = "name,bytes_out,bytes_in,\ncom.example.helper.42,10,20,\n\"my,app.43\",30,40,\ninvalid,1,2,\n"
        let rows = ProcessCSV.parse(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].pid, 42)
        XCTAssertEqual(rows[0].name, "com.example.helper")
        XCTAssertEqual(rows[0].received, 20)
        XCTAssertEqual(rows[0].sent, 10)
        XCTAssertEqual(rows[1].name, "my,app")
    }
    func testCSVUsesLatestSampleAndRejectsMissingHeadersOrPartialRows() {
        let text = ",bytes_in,bytes_out,\napp.1,10,20,\n,bytes_in,bytes_out,\napp.1,30,40,\napp.2,3,\n"
        XCTAssertEqual(ProcessCSV.parse(text).count, 1)
        XCTAssertEqual(ProcessCSV.parse(text).first?.received, 30)
        XCTAssertTrue(ProcessCSV.parse("app.1,10,20,").isEmpty)
    }
    func testProcessRatesUseBaselinesAndActualTime() {
        var calculator = ProcessRateCalculator()
        XCTAssertNil(calculator.consume([.init(pid: 1, name: "app", received: 100, sent: 200)], time: 1)[0].download)
        let rates = calculator.consume([.init(pid: 1, name: "app", received: 1100, sent: 700)], time: 3)
        XCTAssertEqual(rates[0].download, 500)
        XCTAssertEqual(rates[0].upload, 250)
        XCTAssertNil(calculator.consume([.init(pid: 1, name: "new-app", received: 2000, sent: 2000)], time: 4)[0].download)
        XCTAssertNil(calculator.consume([.init(pid: 1, name: "new-app", received: 1, sent: 1)], time: 5)[0].download)
        calculator.reset()
        XCTAssertNil(calculator.consume([.init(pid: 1, name: "new-app", received: 100, sent: 100)], time: 6)[0].download)
    }
    func testCommandDrainsOutputAndReturnsStatus() async throws {
        let result = try await BoundedCommand.run(executable: "/bin/echo", arguments: ["sample"], timeout: 1)
        XCTAssertEqual(result.text, "sample\n")
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
    }
    func testMissingSampleUsesActualGapAndLongGapStartsNewBaseline() {
        var calculator = ProcessRateCalculator()
        _ = calculator.consume([.init(pid: 1, name: "app", received: 100, sent: 200)], time: 1)
        // An unavailable poll does not supply counters. Only the next complete sample enters the calculator.
        let rates = calculator.consume([.init(pid: 1, name: "app", received: 5100, sent: 2200),
                                        .init(pid: 2, name: "new", received: 9000, sent: 3000)], time: 11)
        XCTAssertEqual(rates.first { $0.pid == 1 }?.download, 500)
        XCTAssertEqual(rates.first { $0.pid == 1 }?.upload, 200)
        XCTAssertNil(rates.first { $0.pid == 2 }?.download)
        XCTAssertNil(calculator.consume([.init(pid: 1, name: "app", received: 8100, sent: 4000)], time: 27)[0].download)
        _ = calculator.consume([], time: 28)
        XCTAssertNil(calculator.consume([.init(pid: 1, name: "app", received: 10100, sent: 5000)], time: 29)[0].download)
    }
    func testCommandTimeoutStopsChild() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await BoundedCommand.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotNil(result.status)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }
    func testCommandEscalatesWhenChildIgnoresTerminate() async throws {
        let result = try await BoundedCommand.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, 9)
    }
    func testHeavyOutputIsCappedAndDoesNotPreventTimeout() async throws {
        let result = try await BoundedCommand.run(executable: "/usr/bin/yes", arguments: [], timeout: 0.1, outputLimit: 1024)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.utf8.count, 1024)
    }
    func testCancellationStopsActualCommand() async throws {
        let worker = Task { try await BoundedCommand.run(executable: "/bin/sleep", arguments: ["10"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(50))
        worker.cancel()
        let result = try await worker.value
        XCTAssertTrue(result.cancelled)
        XCTAssertNotNil(result.status)
        XCTAssertFalse(result.timedOut)
    }
}
