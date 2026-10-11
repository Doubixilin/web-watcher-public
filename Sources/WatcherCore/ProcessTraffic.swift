import Foundation
import Combine

public struct ProcessCounter: Sendable {
    public let pid: Int32
    public let name: String
    public let received: UInt64
    public let sent: UInt64
    public init(pid: Int32, name: String, received: UInt64, sent: UInt64) {
        self.pid = pid; self.name = name; self.received = received; self.sent = sent
    }
}
public struct ProcessRate: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let download: Double?
    public let upload: Double?
}

public enum ProcessCSV {
    public static func parse(_ text: String) -> [ProcessCounter] {
        var downloadIndex: Int?, uploadIndex: Int?
        var result: [Int32: ProcessCounter] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = split(String(line))
            if let down = columns.firstIndex(of: "bytes_in"), let up = columns.firstIndex(of: "bytes_out") {
                downloadIndex = down; uploadIndex = up; result = [:]; continue
            }
            guard let down = downloadIndex, let up = uploadIndex, columns.count > max(down, up),
                  let identity = columns.first, let dot = identity.lastIndex(of: "."),
                  let pid = Int32(identity[identity.index(after: dot)...]), pid > 0,
                  let received = UInt64(columns[down]), let sent = UInt64(columns[up]) else { continue }
            result[pid] = .init(pid: pid, name: String(identity[..<dot]), received: received, sent: sent)
        }
        return result.values.sorted { $0.pid < $1.pid }
    }
    private static func split(_ line: String) -> [String] {
        var fields: [String] = [], field = "", quoted = false
        var iterator = line.makeIterator()
        var char = iterator.next()
        while let current = char {
            if current == "\"" {
                let next = iterator.next()
                if quoted && next == "\"" { field.append("\""); char = iterator.next(); continue }
                quoted.toggle(); char = next; continue
            }
            if current == "," && !quoted { fields.append(field); field = "" } else { field.append(current) }
            char = iterator.next()
        }
        fields.append(field)
        return fields
    }
}

public struct ProcessRateCalculator: Sendable {
    private var previous: [Int32: ProcessCounter] = [:]
    private var previousTime: TimeInterval?
    public init() {}
    public mutating func reset() { previous = [:]; previousTime = nil }
    public mutating func consume(_ counters: [ProcessCounter], time: TimeInterval) -> [ProcessRate] {
        let elapsed = previousTime.map { time - $0 }
        defer { previous = Dictionary(uniqueKeysWithValues: counters.map { ($0.pid, $0) }); previousTime = time }
        return counters.map { value in
            var down: Double?, up: Double?
            if let before = previous[value.pid], before.name == value.name, let elapsed, elapsed > 0, elapsed <= 15,
               value.received >= before.received, value.sent >= before.sent {
                down = Double(value.received - before.received) / elapsed; up = Double(value.sent - before.sent) / elapsed
            }
            return .init(pid: value.pid, name: value.name, download: down, upload: up)
        }.sorted { max($0.download ?? -1, $0.upload ?? -1) > max($1.download ?? -1, $1.upload ?? -1) }
    }
}

@MainActor
public final class ProcessTrafficSession: ObservableObject {
    @Published public private(set) var rates: [ProcessRate] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var isSampling = false
    @Published public private(set) var message = "按需读取进程流量，开启后每次采样之间等待 3 秒。"
    @Published public private(set) var updatedAt: Date?
    private var task: Task<Void, Never>?
    private var calculator = ProcessRateCalculator()
    public init() {}

    public func start() {
        guard task == nil else { return }
        calculator.reset(); rates = []; updatedAt = nil
        isRunning = true; message = "正在读取进程统计…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.isRunning = false; self.isSampling = false }
            var failures = 0
            while !Task.isCancelled {
                self.isSampling = true
                let output = try? await BoundedCommand.run(executable: "/usr/bin/nettop",
                    arguments: ["-P", "-L", "2", "-n", "-x", "-J", "bytes_in,bytes_out"], timeout: 3)
                guard !Task.isCancelled else { break }
                self.isSampling = false
                if let output, output.status == 0, !output.timedOut, !output.truncated, !output.cancelled {
                    let counters = ProcessCSV.parse(output.text)
                    if !counters.isEmpty {
                        self.rates = self.calculator.consume(counters, time: ProcessInfo.processInfo.systemUptime)
                        self.updatedAt = Date(); failures = 0
                        self.message = self.rates.contains { $0.download != nil } ? "按进程统计；代理与共享辅助进程可能影响软件归属。" : "已读取进程，等待第二次样本计算速率。"
                    } else { failures += 1; self.invalidate("系统未返回可用的进程统计。") }
                } else {
                    failures += 1
                    self.invalidate(output?.timedOut == true ? "本次进程采样超时，独立网络监测仍在运行。" : "本次进程统计不可用，独立网络监测仍在运行。")
                }
                if failures >= 3 { self.message += " 已暂停采样，可点击重新开启。"; break }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }
    public func stop() { isRunning = false; task?.cancel(); calculator.reset(); rates = []; updatedAt = nil }
    // Clear failed samples from the display; a later valid sample can use a recent valid baseline.
    // The calculator rejects gaps over 15 seconds, PID/name changes and counter rollbacks.
    private func invalidate(_ reason: String) { rates = []; updatedAt = nil; message = reason }
}
