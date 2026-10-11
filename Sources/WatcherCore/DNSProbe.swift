import Foundation
import Darwin
import dnssd

// Owned by the polling task; callbacks run synchronously inside DNSServiceProcessResult.
private final class DNSAnswers {
    var addresses: [String] = []
    var interfaceIndices: Set<UInt32> = []
    var error: DNSServiceErrorType?
    var batchComplete = false
}

enum DNSProbe {
    static func run(_ target: ProbeTarget) async -> ProbeResult {
        // Poll off the UI thread with a deadline; cancellation also stops the actual resolver operation.
        let worker = Task.detached { resolve(target) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private static func resolve(_ target: ProbeTarget) -> ProbeResult {
        let date = Date(), start = ProcessInfo.processInfo.systemUptime
        let answers = DNSAnswers()
        var service: DNSServiceRef?
        let code = DNSServiceGetAddrInfo(&service, DNSServiceFlags(kDNSServiceFlagsTimeout), 0, 0, target.host,
            { _, flags, index, error, _, address, _, context in
                guard let context else { return }
                let state = Unmanaged<DNSAnswers>.fromOpaque(context).takeUnretainedValue()
                if error == kDNSServiceErr_NoError, let address, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
                   let value = numericAddress(address) {
                    if !state.addresses.contains(value) { state.addresses.append(value) }
                    state.interfaceIndices.insert(index)
                } else if error != kDNSServiceErr_NoError { state.error = error }
                state.batchComplete = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0
            }, Unmanaged.passUnretained(answers).toOpaque())
        defer { if let service { DNSServiceRefDeallocate(service) } }
        if code != kDNSServiceErr_NoError { answers.error = code }
        if code == kDNSServiceErr_NoError, let service {
            let descriptor = DNSServiceRefSockFD(service)
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime - start < target.timeout {
                var fd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&fd, 1, 100)
                if ready > 0 {
                    let result = DNSServiceProcessResult(service)
                    if result != kDNSServiceErr_NoError { answers.error = result; break }
                    if answers.batchComplete && !answers.addresses.isEmpty { break }
                    if answers.batchComplete, let error = answers.error, error != kDNSServiceErr_NoSuchRecord { break }
                } else if ready < 0 && errno != EINTR { break }
            }
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let success = !Task.isCancelled && !answers.addresses.isEmpty
        let detail = success ? answers.addresses.joined(separator: "、") :
            (Task.isCancelled ? "检测已取消" : answers.error.map { "系统解析未返回可用地址（代码 \($0)）" } ?? "系统解析超时")
        var path = ObservedPath()
        let indices = answers.interfaceIndices.filter { $0 > 0 && $0 < UInt32.max - 10 }.sorted()
        path.note = "系统解析（可能命中缓存），测量到首批可用地址；解析服务器与物理出口未验证。回调接口索引：\(indices.map(String.init).joined(separator: ", "))"
        return .init(target: target, startedAt: date, elapsedMS: elapsed, reachable: success,
                     phases: [.init(.dns, success ? .succeeded : .failed, milliseconds: elapsed, detail: detail)],
                     path: path, detail: success ? "解析成功；地址可能由代理合成，不证明目标服务可达。" : detail)
    }
}
