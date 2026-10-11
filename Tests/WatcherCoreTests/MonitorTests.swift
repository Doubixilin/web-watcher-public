import XCTest
@testable import WatcherCore

@MainActor
final class MonitorTests: XCTestCase {
    func testRepeatedStartAndManualCheckDoNotOverlap() async throws {
        let runner = DelayedRunner()
        let monitor = MonitorSession(targets: [.defaults[0], .defaults[1]], runner: runner)
        monitor.start()
        for _ in 0..<10 { monitor.start(); monitor.checkNow() }
        try await waitUntil { monitor.completedRounds == 1 }
        XCTAssertEqual(monitor.completedRounds, 1)
        let maximum = await runner.maximum
        XCTAssertEqual(maximum, 1)
        monitor.pause()
    }

    func testPauseCancelsRoundAndDoesNotPublishPartialResults() async throws {
        let runner = DelayedRunner()
        let monitor = MonitorSession(targets: [.defaults[0], .defaults[1]], runner: runner)
        monitor.start()
        try await Task.sleep(for: .milliseconds(10))
        monitor.pause()
        XCTAssertFalse(monitor.isRunning)
        try await waitUntil { !monitor.isProbing }
        XCTAssertFalse(monitor.isProbing)
        XCTAssertEqual(monitor.completedRounds, 0)
        XCTAssertTrue(monitor.results.isEmpty)
        XCTAssertNil(monitor.nextCheckAt)
        monitor.start()
        try await waitUntil { monitor.completedRounds == 1 }
        XCTAssertEqual(monitor.completedRounds, 1)
        monitor.pause()
    }

    func testManualProbeWhilePausedDoesNotEnableContinuousMonitoring() async throws {
        let monitor = MonitorSession(targets: [.defaults[0]], runner: DelayedRunner())
        monitor.checkNow()
        try await waitUntil { monitor.completedRounds == 1 }
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(monitor.isProbing)
        XCTAssertEqual(monitor.completedRounds, 1)
        XCTAssertNil(monitor.nextCheckAt)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "调度状态未在限定时间内完成")
    }
}

private actor DelayedRunner: ProbeRunning {
    private var active = 0
    private(set) var maximum = 0
    func probe(_ target: ProbeTarget) async -> ProbeResult {
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try? await Task.sleep(for: .milliseconds(40))
        return .init(target: target, startedAt: .now, elapsedMS: 40, reachable: true, phases: [], detail: "模拟结果")
    }
}
