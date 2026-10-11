import XCTest
@testable import WatcherCore

final class RecoveryPolicyTests: XCTestCase {
    private func sample(_ state: WiFiLinkState = .associated, name: String? = "main", interface: String? = "en1") -> WiFiLinkSnapshot {
        .init(interface: interface, name: name, state: state, hasAddress: state == .associated)
    }
    func testDisconnectDebounceAndUnknownNeverTriggers() {
        var policy = RecoveryPolicy()
        XCTAssertFalse(policy.observe(sample(), now: 0))
        XCTAssertFalse(policy.observe(sample(.disconnected, name: nil), now: 6))
        XCTAssertFalse(policy.observe(sample(.disconnected, name: nil), now: 8))
        XCTAssertTrue(policy.observe(sample(.disconnected, name: nil), now: 10))
        XCTAssertFalse(policy.observe(sample(.unknown, name: nil), now: 11))
        XCTAssertFalse(policy.observe(sample(.poweredOff, name: nil), now: 12))
        XCTAssertFalse(policy.observe(sample(.disconnected, name: nil), now: 13))
    }
    func testThreeIndependentFailuresNeedTwoConsecutiveRounds() {
        var policy = RecoveryPolicy()
        XCTAssertFalse(policy.consume(.init(successes: 0, failures: 3), now: 10))
        XCTAssertFalse(policy.consume(.init(successes: 1, failures: 2), now: 20))
        XCTAssertEqual(policy.failures, 0)
        XCTAssertFalse(policy.consume(.init(successes: 0, failures: 3), now: 30))
        XCTAssertFalse(policy.consume(.init(successes: 0, failures: 2, unknown: 1), now: 40))
        XCTAssertFalse(policy.consume(.init(successes: 0, failures: 3), now: 50))
        XCTAssertTrue(policy.consume(.init(successes: 0, failures: 3), now: 60))
        XCTAssertFalse(WiFiHealth(successes: 1, failures: 2).verified)
        XCTAssertTrue(WiFiHealth(successes: 2, failures: 1).verified)
    }
    func testManualChangeAndCooldownPreventPingPong() {
        var policy = RecoveryPolicy()
        _ = policy.observe(sample(), now: 0)
        _ = policy.observe(sample(name: "backup"), now: 5)
        XCTAssertEqual(policy.holdUntil, 65)
        XCTAssertFalse(policy.consume(.init(successes: 0, failures: 3), now: 10))
        XCTAssertFalse(policy.consume(.init(successes: 0, failures: 3), now: 20))
        policy.reset(holdingUntil: 140)
        _ = policy.observe(sample(name: "another"), now: 21)
        XCTAssertEqual(policy.holdUntil, 140, "关联变化不能缩短恢复冷却")
    }
    func testObservationGapAndInterfaceChangeRebuildBaseline() {
        var policy = RecoveryPolicy()
        _ = policy.observe(sample(), now: 0)
        _ = policy.consume(.init(successes: 0, failures: 3), now: 1)
        XCTAssertFalse(policy.observe(sample(.disconnected, name: nil), now: 30))
        XCTAssertEqual(policy.failures, 0)
        XCTAssertEqual(policy.holdUntil, 45)
        XCTAssertFalse(policy.observe(sample(.disconnected, name: nil, interface: "en2"), now: 32))
    }
    func testOnlySavedDistinctCandidatesInOrderExcludingCurrent() {
        XCTAssertEqual(RecoveryPolicy.candidates(primary: "main", backups: ["backup", "backup", "unknown", "other"], current: "main", saved: ["main", "backup", "other"]), ["backup", "other"])
        XCTAssertEqual(RecoveryPolicy.candidates(primary: "main", backups: ["backup"], current: "backup", saved: ["main", "backup"]), ["main"])
    }
}

@MainActor
final class RecoverySessionTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    private func session(_ adapter: MockWiFiAdapter, clock: TestClock) -> RecoverySession {
        let session = RecoverySession(adapter: adapter, journalURL: directory.appendingPathComponent("events.json"), verificationTimeout: 0, clock: { clock.time })
        session.configure(enabled: true, monitoring: true, authorized: true, primary: "main", backups: ["backup"])
        return session
    }
    private func trigger(_ session: RecoverySession, clock: TestClock) async {
        await session.tick() // initial association baseline
        clock.time = 5; await session.tick()
        clock.time = 15; await session.tick()
        XCTAssertTrue(session.isBusy)
    }
    private func assertRequests(_ adapter: MockWiFiAdapter, _ expected: [String]) async {
        let requests = await adapter.requested()
        XCTAssertEqual(requests, expected)
    }
    private func settle(_ session: RecoverySession) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while session.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isBusy)
    }
    func testFailureSwitchesAndVerifiesThenKeepsBackupDuringCooldown() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter()
        let recovery = session(adapter, clock: clock)
        await trigger(recovery, clock: clock); try await settle(recovery)
        await assertRequests(adapter, ["backup"])
        XCTAssertTrue(recovery.events.contains { $0.kind == "recoveryVerified" })
        XCTAssertEqual(recovery.snapshot?.name, "backup")
        clock.time = 16; await recovery.tick()
        await assertRequests(adapter, ["backup"])
        let journal = RecoveryJournal(url: directory.appendingPathComponent("events.json"))
        XCTAssertTrue(journal.events.contains { $0.kind == "recoveryVerified" })
    }
    func testConfirmedDisconnectDoesNotWaitForWebsiteRounds() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter()
        let recovery = session(adapter, clock: clock)
        await recovery.tick()
        await adapter.disconnect()
        clock.time = 6; await recovery.tick()
        XCTAssertFalse(recovery.isBusy)
        clock.time = 10; await recovery.tick(); try await settle(recovery)
        await assertRequests(adapter, ["backup"])
        XCTAssertTrue(recovery.events.contains { $0.kind == "wifiLinkDown" })
        XCTAssertTrue(recovery.events.contains { $0.kind == "recoveryVerified" })
    }
    func testReconnectionBeforeAttemptKeepsExistingNetwork() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter(recoversBeforeConnection: true)
        let recovery = session(adapter, clock: clock)
        await trigger(recovery, clock: clock); try await settle(recovery)
        await assertRequests(adapter, [])
        XCTAssertTrue(recovery.events.contains { $0.kind == "recoveryNotNeeded" })
    }
    func testLongRecoveryWaitDoesNotShortenSuccessCooldown() async throws {
        let clock = TestClock()
        let adapter = MockWiFiAdapter(onConnect: { await MainActor.run { clock.time = 45 } })
        let recovery = session(adapter, clock: clock)
        await trigger(recovery, clock: clock); try await settle(recovery)
        await adapter.makeBackupUnhealthy()
        for time: TimeInterval in [46, 56, 66, 76] { clock.time = time; await recovery.tick() }
        XCTAssertEqual(recovery.events.filter { $0.kind == "recoveryTriggered" }.count, 1)
        await assertRequests(adapter, ["backup"])
    }
    func testManualVerificationWorksWithAutoRecoveryOff() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter()
        let recovery = session(adapter, clock: clock)
        recovery.configure(enabled: false, monitoring: true, authorized: true, primary: "main", backups: ["backup"])
        await recovery.tick()
        recovery.connectManually(to: "unapproved")
        XCTAssertFalse(recovery.isBusy)
        recovery.connectManually(to: "backup")
        XCTAssertTrue(recovery.isBusy)
        try await settle(recovery)
        await assertRequests(adapter, ["backup"])
        XCTAssertTrue(recovery.events.contains { $0.kind == "recoveryVerified" })
    }
    func testCommandSuccessWithoutConnectivityFailsAndRollsBack() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter(backupHealthy: false)
        let recovery = session(adapter, clock: clock)
        await trigger(recovery, clock: clock); try await settle(recovery)
        await assertRequests(adapter, ["backup", "main"])
        XCTAssertFalse(recovery.events.contains { $0.kind == "recoveryVerified" })
        XCTAssertTrue(recovery.events.contains { $0.kind == "recoveryFailed" })
    }
    func testProxyWebsiteFailureDoesNotDiscardUsableWirelessExit() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter(websiteHealthy: false)
        let recovery = session(adapter, clock: clock)
        await trigger(recovery, clock: clock); try await settle(recovery)
        await assertRequests(adapter, ["backup"])
        XCTAssertTrue(recovery.title.contains("网站路径异常"))
    }
    func testDisablingWhileConnectingStopsFurtherAttempts() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter(backupHealthy: false, delayed: true)
        let recovery = session(adapter, clock: clock)
        await trigger(recovery, clock: clock)
        while await adapter.requested().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        recovery.configure(enabled: false, monitoring: true, authorized: true, primary: "main", backups: ["backup"])
        try await settle(recovery)
        await assertRequests(adapter, ["backup"])
        XCTAssertFalse(recovery.events.contains { $0.kind == "recoveryVerified" })
    }
    func testManualChangeDuringAttemptStopsCandidateChain() async throws {
        let clock = TestClock(), adapter = MockWiFiAdapter(externalChange: true)
        let recovery = session(adapter, clock: clock)
        await trigger(recovery, clock: clock); try await settle(recovery)
        await assertRequests(adapter, ["backup"])
        XCTAssertTrue(recovery.events.contains { $0.kind == "externalChange" })
    }
    func testMissingPermissionPauseAndPowerOffDoNotConnect() async {
        let clock = TestClock(), adapter = MockWiFiAdapter(poweredOff: true)
        let recovery = session(adapter, clock: clock)
        await recovery.tick(); clock.time = 6; await recovery.tick()
        recovery.configure(enabled: true, monitoring: true, authorized: false, primary: "main", backups: ["backup"])
        clock.time = 20; await recovery.tick()
        recovery.configure(enabled: true, monitoring: false, authorized: true, primary: "main", backups: ["backup"])
        clock.time = 40; await recovery.tick()
        await assertRequests(adapter, [])
    }
    func testUnreadableHistoryIsPreservedAndBlocksRecovery() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("events.json")
        try Data("broken".utf8).write(to: file)
        let clock = TestClock(), adapter = MockWiFiAdapter()
        let recovery = session(adapter, clock: clock)
        await recovery.tick(); clock.time = 5; await recovery.tick(); clock.time = 15; await recovery.tick()
        XCTAssertNotNil(recovery.storageError)
        await assertRequests(adapter, [])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
    func testJournalBoundedRetentionAndRestart() throws {
        let url = directory.appendingPathComponent("events.json")
        let journal = RecoveryJournal(url: url)
        for index in 0..<503 { journal.append(.init(kind: "sample", message: "\(index)")) }
        let restored = RecoveryJournal(url: url)
        XCTAssertEqual(restored.events.count, 500)
        XCTAssertEqual(restored.events.first?.message, "3")
        XCTAssertEqual(restored.events.last?.message, "502")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}

@MainActor private final class TestClock { var time: TimeInterval = 0 }

private actor MockWiFiAdapter: WiFiRecoveryAdapting {
    var name = "main"
    var requests: [String] = []
    var backupHealthy: Bool
    let websiteHealthy: Bool
    let delayed: Bool
    let externalChange: Bool
    let poweredOff: Bool
    let recoversBeforeConnection: Bool
    var state: WiFiLinkState = .associated
    var healthCalls = 0
    let onConnect: (@Sendable () async -> Void)?
    init(backupHealthy: Bool = true, websiteHealthy: Bool = true, delayed: Bool = false, externalChange: Bool = false, poweredOff: Bool = false, recoversBeforeConnection: Bool = false, onConnect: (@Sendable () async -> Void)? = nil) {
        self.backupHealthy = backupHealthy; self.websiteHealthy = websiteHealthy
        self.delayed = delayed; self.externalChange = externalChange; self.poweredOff = poweredOff
        self.recoversBeforeConnection = recoversBeforeConnection
        self.onConnect = onConnect
    }
    func snapshot() -> WiFiLinkSnapshot { .init(interface: "en1", name: state == .associated ? name : nil, state: poweredOff ? .poweredOff : state, hasAddress: !poweredOff && state == .associated) }
    func savedNames() -> [String] { ["main", "backup"] }
    func health(interface: String) -> WiFiHealth {
        healthCalls += 1
        return (name == "backup" && backupHealthy) || (recoversBeforeConnection && healthCalls >= 3) ? .init(successes: 3, failures: 0) : .init(successes: 0, failures: 3)
    }
    func connect(interface: String, name: String) async -> String? {
        requests.append(name)
        if delayed { try? await Task.sleep(for: .milliseconds(500)) }
        await onConnect?()
        self.name = externalChange ? "user-selected" : name
        state = .associated
        return nil
    }
    func websiteReachable() -> Bool { websiteHealthy }
    func requested() -> [String] { requests }
    func disconnect() { state = .disconnected }
    func makeBackupUnhealthy() { backupHealthy = false }
}
