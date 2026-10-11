import Foundation
import Darwin

public struct CommandOutput: Sendable {
    public let text: String
    public let status: Int32?
    public let timedOut: Bool
    public let truncated: Bool
    public let cancelled: Bool
}

public enum BoundedCommand {
    private static let registry = CommandRegistry()
    public static func stopAll() { registry.stopAll() }
    public static func run(executable: String, arguments: [String], timeout: TimeInterval = 3,
                           outputLimit: Int = 1_048_576) async throws -> CommandOutput {
        let worker = Task.detached(priority: .utility) { try execute(executable, arguments, timeout, outputLimit) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func execute(_ executable: String, _ arguments: [String], _ timeout: TimeInterval, _ limit: Int) throws -> CommandOutput {
        guard !Task.isCancelled else { return .init(text: "", status: nil, timedOut: false, truncated: false, cancelled: true) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NSUnbufferedIO"] = "YES"; environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try registry.launch(process)
        defer { registry.remove(process) }
        output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        let descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        defer { output.fileHandleForReading.closeFile(); errors.fileHandleForReading.closeFile() }
        var captured = Data(), truncated = false, timedOut = false, cancelled = false
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var stopDeadline: TimeInterval?
        var killed = false
        var open = [true, true]
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while process.isRunning || open.contains(true) {
            let now = ProcessInfo.processInfo.systemUptime
            if stopDeadline == nil && (Task.isCancelled || now >= deadline) {
                cancelled = Task.isCancelled; timedOut = !cancelled
                if process.isRunning { process.terminate() }
                stopDeadline = now + 0.25
            }
            if let stopDeadline, now >= stopDeadline {
                if process.isRunning && !killed { _ = kill(process.processIdentifier, SIGKILL); killed = true }
                if now >= stopDeadline + 0.5 { break }
            }
            var polls = descriptors.enumerated().map { pollfd(fd: open[$0.offset] ? $0.element : -1, events: Int16(POLLIN), revents: 0) }
            _ = poll(&polls, nfds_t(polls.count), 25)
            for index in descriptors.indices where open[index] {
                // Drain both pipes regardless of capture limit; bounded work keeps deadlines effective under heavy output.
                for _ in 0..<32 {
                    let count = read(descriptors[index], &buffer, buffer.count)
                    if count == 0 { open[index] = false; break }
                    if count < 0 { if errno != EAGAIN && errno != EINTR { open[index] = false }; break }
                    if index == 0 {
                        let remaining = max(0, limit - captured.count)
                        captured.append(contentsOf: buffer.prefix(min(count, remaining)))
                        if count > remaining { truncated = true }
                    }
                }
            }
        }
        return .init(text: String(decoding: captured, as: UTF8.self), status: process.isRunning ? nil : process.terminationStatus,
                     timedOut: timedOut, truncated: truncated, cancelled: cancelled)
    }
}

private final class CommandRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [Int32: Process] = [:]
    private var stopping = false
    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !stopping else { throw CancellationError() }
            try process.run()
            active[process.processIdentifier] = process
        }
    }
    func remove(_ process: Process) { lock.withLock { _ = active.removeValue(forKey: process.processIdentifier) } }
    func stopAll() {
        lock.withLock {
            stopping = true
            for (pid, process) in active where process.isRunning { _ = kill(pid, SIGKILL) }
        }
    }
}
