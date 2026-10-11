import Foundation
import Combine

public struct SystemProbeRunner: ProbeRunning {
    public init() {}
    public func probe(_ target: ProbeTarget) async -> ProbeResult {
        switch target.kind {
        case .dns: await DNSProbe.run(target)
        case .tcp: await TCPProbe.run(target)
        case .http: await HTTPProbe.run(target)
        }
    }
}

@MainActor
public final class MonitorSession: ObservableObject {
    @Published public private(set) var results: [ProbeResult] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var isProbing = false
    @Published public private(set) var completedRounds = 0
    @Published public private(set) var environment = NetworkEnvironment.capture()
    @Published public private(set) var nextCheckAt: Date?
    @Published public private(set) var trends: [ProbeTrendPoint] = []
    public let targets: [ProbeTarget]
    public let interval: TimeInterval
    private let runner: any ProbeRunning
    private var task: Task<Void, Never>?
    private var generation = 0
    public var assessment: RoundAssessment { .evaluate(results) }

    public init(targets: [ProbeTarget] = ProbeTarget.defaults, interval: TimeInterval = 30,
                runner: any ProbeRunning = SystemProbeRunner()) {
        self.targets = targets; self.interval = max(1, interval); self.runner = runner
    }

    public func start() {
        guard task == nil else { return }
        isRunning = true
        launch(repeating: true)
    }

    public func checkNow() {
        // Never cancel a probe to start another, and never overlap rounds.
        guard !isProbing else { return }
        let repeating = isRunning
        task?.cancel(); task = nil
        launch(repeating: repeating)
    }

    public func pause() {
        task?.cancel()
        isRunning = false; nextCheckAt = nil
    }

    private func launch(repeating: Bool) {
        generation += 1
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == self.generation {
                    self.task = nil; self.isProbing = false; self.nextCheckAt = nil
                }
            }
            repeat {
                guard !Task.isCancelled, token == self.generation else { return }
                self.nextCheckAt = nil
                self.isProbing = true
                let environment = await Task.detached(priority: .utility) { NetworkEnvironment.capture() }.value
                guard !Task.isCancelled, token == self.generation else { return }
                self.environment = environment
                var round: [ProbeResult] = []
                // Four small probes, sequentially: bounded traffic, no concurrency pile-up.
                for target in self.targets {
                    guard !Task.isCancelled else { break }
                    round.append(await self.runner.probe(target))
                }
                guard !Task.isCancelled, token == self.generation else { return }
                self.results = round
                self.trends.append(contentsOf: round.map { .init(targetID: $0.id, name: $0.target.name, date: $0.startedAt, milliseconds: $0.elapsedMS, reachable: $0.reachable) })
                if self.trends.count > 480 { self.trends.removeFirst(self.trends.count - 480) }
                self.completedRounds += 1
                self.isProbing = false
                guard repeating else { break }
                self.nextCheckAt = Date().addingTimeInterval(self.interval)
                do { try await Task.sleep(for: .seconds(self.interval)) } catch { return }
            } while !Task.isCancelled
            if token == self.generation { self.task = nil }
        }
    }
}

public struct ProbeTrendPoint: Identifiable, Sendable {
    public let id = UUID()
    public let targetID: String
    public let name: String
    public let date: Date
    public let milliseconds: Double
    public let reachable: Bool
}
