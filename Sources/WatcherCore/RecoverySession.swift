import Foundation
import Combine

@MainActor
public final class RecoverySession: ObservableObject {
    @Published public private(set) var title = "自动恢复未开启"
    @Published public private(set) var detail = "开启后仅在确认异常时尝试已保存候选；不会自动切回主网络。"
    @Published public private(set) var snapshot: WiFiLinkSnapshot?
    @Published public private(set) var health: WiFiHealth?
    @Published public private(set) var events: [RecoveryEvent] = []
    @Published public private(set) var isBusy = false
    public var onNetworkChange: (() -> Void)?
    public var storageError: String? { journal.error }
    public var historyURL: URL { journal.url }
    private let adapter: any WiFiRecoveryAdapting
    private let journal: RecoveryJournal
    private var policy = RecoveryPolicy()
    private var task: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var enabled = false
    private var monitoring = true
    private var authorized = false
    private var primary = ""
    private var backups: [String] = []
    private var suspended = false
    private var lastName: String?
    private var previous: WiFiLinkSnapshot?
    private var lastTick: TimeInterval?
    private var nextHealth: TimeInterval = 0
    private var downAt: TimeInterval?
    private var noAddressAt: TimeInterval?
    private var configurationVersion = 0
    private let verificationTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let clock: @MainActor () -> TimeInterval

    public init(adapter: any WiFiRecoveryAdapting = SystemWiFiRecoveryAdapter(), journalURL: URL? = nil,
                verificationTimeout: TimeInterval = 12, pollInterval: TimeInterval = 2,
                clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.adapter = adapter
        self.verificationTimeout = verificationTimeout; self.pollInterval = pollInterval
        self.clock = clock
        let url = journalURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebWatcher/recovery-events.json")
        journal = RecoveryJournal(url: url); events = journal.events
    }
    public func configure(enabled: Bool, monitoring: Bool, authorized: Bool, primary: String, backups: [String]) {
        guard self.enabled != enabled || self.monitoring != monitoring || self.authorized != authorized || self.primary != primary || self.backups != backups else { return }
        operation?.cancel()
        configurationVersion += 1
        self.enabled = enabled; self.monitoring = monitoring; self.authorized = authorized
        self.primary = primary; self.backups = backups
        policy.reset(holdingUntil: now + 5); nextHealth = 0
        record("configuration", enabled && monitoring ? "自动恢复配置已更新，重新建立观测基线。" : "自动恢复已暂停。")
        updateAvailability()
    }
    public func start() {
        guard task == nil else { return }
        record("observationGap", "开始观测；应用退出或休眠期间的网络情况未知。")
        policy.reset(holdingUntil: now + 5)
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.suspended && !self.isBusy { await self.tick() }
                do { try await Task.sleep(for: .seconds(self.pollInterval)) } catch { break }
            }
        }
    }
    public func stop() { task?.cancel(); task = nil; operation?.cancel() }
    public func signalChange() { nextHealth = 0; onNetworkChange?() }
    public func suspend() {
        suspended = true; operation?.cancel(); policy.reset(); lastTick = nil
        record("observationGap", "系统进入休眠，暂停恢复；此间不推断断网。")
    }
    public func resume() {
        suspended = false; policy.reset(holdingUntil: now + 15); nextHealth = 0
        record("observationGap", "系统唤醒；留出 15 秒重新建立网络配置。")
    }
    public func recordObserverFallback() { record("observer", "系统事件订阅受限，使用每 2 秒状态复核。") }
    public func connectManually(to name: String) {
        guard primary == name || backups.contains(name) else { return }
        launchRecovery(reason: "用户请求连接并验证候选", manualCandidate: name)
    }
    private var now: TimeInterval { clock() }
    private var allowed: Bool { enabled && monitoring && authorized && !suspended && journal.error == nil }
    private func permitted(manual: Bool) -> Bool { manual ? authorized && !suspended && journal.error == nil : allowed }

    private func record(_ kind: String, _ message: String, health: WiFiHealth? = nil) {
        journal.append(.init(kind: kind, message: message, wifi: snapshot, health: health))
        events = journal.events
    }
    private func updateAvailability() {
        if journal.error != nil { title = "恢复受限"; detail = journal.error! }
        else if !enabled { title = "自动恢复未开启"; detail = "故障记录继续；开启后才会请求连接候选网络。" }
        else if !monitoring { title = "自动恢复已暂停"; detail = "继续网站监测后恢复判断。" }
        else if !authorized { title = "恢复受限 · 需要 Wi-Fi 授权"; detail = "无法核对实际连接的名称时不执行切网。" }
        else if backups.isEmpty && primary.isEmpty { title = "恢复受限 · 尚无候选"; detail = "请指定主网络及备用网络，并先在系统中连接保存凭据。" }
    }

    func tick() async {
        let version = configurationVersion
        let value = await adapter.snapshot()
        guard !Task.isCancelled, !suspended, !isBusy, version == configurationVersion else { return }
        let time = now
        if let lastTick, time - lastTick > 10 {
            policy.reset(holdingUntil: time + 15); downAt = nil; noAddressAt = nil
            record("observationGap", "采样出现间隔，重新建立基线。")
        }
        lastTick = time; snapshot = value
        if previous?.state != value.state || (value.name != nil && previous?.name != value.name) {
            if value.state == .disconnected {
                downAt = time
                record("wifiLinkDown", "观察到 Wi-Fi 链路断开；上次名称：\(lastName ?? "未知")。")
            } else if value.state == .associated {
                let duration = downAt.map { "，观测中断约 \(Int(time - $0)) 秒" } ?? ""
                record("wifiLinkRestored", "观察到 Wi-Fi 关联\(duration)；联网结果另行验证。")
                downAt = nil
            } else {
                record(value.state == .poweredOff ? "wifiPowerOff" : "observationUnknown",
                       value.state == .poweredOff ? "Wi-Fi 已关闭，不自动打开。" : "Wi-Fi 状态证据不足，不据此切网。")
            }
            onNetworkChange?()
        }
        previous = value
        let disconnected = policy.observe(value, now: time)
        if let name = value.name { lastName = name }
        if value.state == .associated && !value.hasAddress {
            if noAddressAt == nil { noAddressAt = time }
        } else { noAddressAt = nil }
        updateAvailability()
        guard allowed else { return }
        if time < policy.holdUntil {
            title = "冷却 / 配置等待"; detail = "约 \(Int(ceil(policy.holdUntil - time))) 秒后允许再次恢复；保持当前连接。"
            return
        }
        if disconnected || (value.name != nil && noAddressAt.map({ time - $0 >= 15 }) == true) {
            launchRecovery(reason: disconnected ? "Wi-Fi 链路持续断开" : "Wi-Fi 关联后 15 秒仍无有效地址")
            return
        }
        guard value.state == .associated, value.hasAddress, value.name != nil, let interface = value.interface else {
            title = "等待有效 Wi-Fi 状态"; detail = "关闭、未知或缺少地址的状态不会记作网站失败。"; return
        }
        guard time >= nextHealth else { return }
        nextHealth = time + 10
        let result = await adapter.health(interface: interface)
        let fresh = await adapter.snapshot()
        guard !Task.isCancelled, allowed, !isBusy, version == configurationVersion, fresh.name == value.name,
              fresh.interface == value.interface, fresh.state == .associated, fresh.hasAddress else {
            policy.reset(holdingUntil: now + 5); return
        }
        health = result
        let shouldRecover = policy.consume(result, now: now)
        if shouldRecover { launchRecovery(reason: "绑定无线接口的 3 个目标连续 2 轮均无法建立 TCP 连接") }
        else if result.allFailed {
            title = "疑似联网异常 · 正在复核"; detail = "已失败 \(policy.failures) 轮；单个目标、HTTP 错误或代理异常不会直接触发切换。"
            record("internetSuspected", detail, health: result)
        } else {
            title = "自动恢复待命"
            detail = "无线接口直连：\(result.successes) 个 TCP 目标可达。网站仍按其实际代理路径独立检测。"
        }
    }

    private func launchRecovery(reason: String, manualCandidate: String? = nil) {
        let manual = manualCandidate != nil
        guard operation == nil, permitted(manual: manual), let interface = snapshot?.interface else { return }
        let origin = lastName
        isBusy = true; title = "正在恢复"; detail = reason
        record("recoveryTriggered", reason, health: health)
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isBusy = false; self.operation = nil; self.nextHealth = 0
                self.lastTick = self.now // Planned connection/verification waits are not an observation gap.
            }
            let saved = await self.adapter.savedNames()
            guard !Task.isCancelled, self.permitted(manual: manual) else { return }
            let candidates = manualCandidate.map { saved.contains($0) ? [$0] : [] }
                ?? RecoveryPolicy.candidates(primary: self.primary, backups: self.backups, current: origin, saved: saved)
            guard !candidates.isEmpty else {
                self.title = "没有可尝试的已保存候选"
                self.detail = "先在系统 Wi-Fi 菜单连接并保存备用网络；仅填写名称不足以完成连接。"
                self.record("recoveryBlocked", self.detail); self.policy.reset(holdingUntil: self.now + 60); return
            }
            var expectedName = origin
            // One pass, then one rollback. No unbounded retries or automatic return to a healthy primary.
            var attempts = candidates
            if let origin, saved.contains(origin), !attempts.contains(origin) { attempts.append(origin) }
            for name in attempts {
                guard !Task.isCancelled, self.permitted(manual: manual) else { self.record("recoveryCancelled", "已停止后续连接请求。"); return }
                let before = await self.adapter.snapshot()
                guard before.interface == interface, before.state != .poweredOff else { return }
                if let observed = before.name, observed != expectedName && observed != origin {
                    self.title = "连接已由其他操作改变"; self.detail = "停止本次恢复并等待 60 秒。"
                    self.record("externalChange", self.detail); self.policy.reset(holdingUntil: self.now + 60); return
                }
                if !manual, before.state == .associated, before.hasAddress {
                    let recovered = await self.adapter.health(interface: interface)
                    let fresh = await self.adapter.snapshot()
                    guard !Task.isCancelled, self.allowed else { return }
                    if fresh.name != before.name || fresh.interface != interface || fresh.state == .poweredOff {
                        self.record("externalChange", "连接在准备期间改变，停止本次恢复。")
                        self.policy.reset(holdingUntil: self.now + 60); return
                    }
                    if fresh.state == .associated && fresh.hasAddress && recovered.successes > 0 {
                        self.snapshot = fresh; self.health = recovered; self.lastName = fresh.name
                        self.title = "当前连接已恢复可达"; self.detail = "切换前复核已有 TCP 目标可达，保持连接。"
                        self.record("recoveryNotNeeded", self.detail, health: recovered)
                        self.policy.reset(holdingUntil: self.now + 60); return
                    }
                }
                self.title = name == origin ? "尝试回退原网络" : "连接备用候选"
                self.detail = name; self.record("connectionRequested", "\(self.title)：\(name)。")
                let error = await self.adapter.connect(interface: interface, name: name)
                guard !Task.isCancelled, self.permitted(manual: manual) else { self.record("recoveryCancelled", "已停止后续请求；系统已受理的连接仍需观察。"); return }
                // Even a failed/timeout command may have changed association; inspect actual state.
                let result = await self.verify(name: name, interface: interface, manual: manual)
                guard !Task.isCancelled, self.permitted(manual: manual) else { return }
                if result {
                    self.lastName = name; self.previous = self.snapshot
                    self.downAt = nil; self.noAddressAt = nil
                    self.policy.reset(holdingUntil: self.now + 120)
                    self.onNetworkChange?(); return
                }
                self.record("candidateFailed", "\(name)：\(error ?? "实际关联或联网验证未通过")。", health: self.health)
                let after = await self.adapter.snapshot()
                if let observed = after.name, observed != name && observed != expectedName {
                    self.title = "连接已由其他操作改变"; self.detail = "已停止本次恢复，保持当前连接。"
                    self.record("externalChange", "发现其他连接，停止继续尝试。")
                    self.policy.reset(holdingUntil: self.now + 60); return
                }
                expectedName = after.name
            }
            self.title = "候选未通过联网验证"
            self.detail = "已尝试备用及原网络；60 秒后重新评估，没有永久停止。"
            self.record("recoveryFailed", self.detail); self.policy.reset(holdingUntil: self.now + 60)
        }
    }
    private func verify(name: String, interface: String, manual: Bool = false) async -> Bool {
        title = "验证连接与联网"; detail = name
        let deadline = now + verificationTimeout
        repeat {
            guard !Task.isCancelled, permitted(manual: manual) else { return false }
            let value = await adapter.snapshot(); snapshot = value
            if value.interface == interface && value.name == name && value.state == .associated && value.hasAddress {
                let result = await adapter.health(interface: interface)
                let fresh = await adapter.snapshot()
                guard fresh.name == name, fresh.interface == interface, fresh.state == .associated, fresh.hasAddress else { return false }
                health = result
                if result.verified {
                    let website = await adapter.websiteReachable()
                    let final = await adapter.snapshot()
                    guard !Task.isCancelled, permitted(manual: manual), final.name == name, final.interface == interface, final.state == .associated, final.hasAddress else { return false }
                    snapshot = final
                    title = website ? "联网验证通过" : "无线出口可达 · 网站路径异常"
                    let duration = downAt.map { "观测中断约 \(Int(now - $0)) 秒。" } ?? ""
                    detail = (website ? "\(name)：至少 2 个直连 TCP 目标与网站 HTTPS 可达；远程会话需独立核验。" : "\(name)：至少 2 个无线直连 TCP 目标可达；请检查代理及网站路径，保持此连接。") + duration
                    record("recoveryVerified", detail, health: result)
                    return true
                }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return false }
        } while now < deadline
        return false
    }
}
