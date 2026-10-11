import SwiftUI
import Charts
import AppKit
import WatcherCore

struct WiFiPane: View {
    @ObservedObject var telemetry: TelemetrySession
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var authorization: WiFiAuthorization
    @ObservedObject var recovery: RecoverySession
    @State private var manualName = ""
    private var names: [String] {
        let configured = [preferences.primaryWiFi] + preferences.backupWiFi + [telemetry.wifi.name ?? ""]
        let rest = (telemetry.savedNetworks + telemetry.nearby.map(\.name)).sorted()
        var seen = Set<String>()
        return (configured + rest).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PermissionCard(authorization: authorization)
                Panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(telemetry.wifi.name ?? "当前 Wi-Fi 名称未提供").font(.title2.weight(.semibold))
                            Text("\(telemetry.wifi.protocolName) · \(telemetry.wifi.interfaceName ?? "接口未知")").foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(alignment: .bottom, spacing: 4) {
                            ForEach(1...4, id: \.self) { level in
                                RoundedRectangle(cornerRadius: 3).fill(level <= telemetry.wifi.signalLevel ? Color.teal : Color.secondary.opacity(0.15)).frame(width: 9, height: CGFloat(10 + level * 8))
                            }
                        }.accessibilityLabel(telemetry.wifi.signalLabel)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 18) {
                        detail("信号强度", telemetry.wifi.rssi.map { "\($0) dBm · \(telemetry.wifi.signalLabel)" } ?? "系统未提供")
                        detail("噪声 / 信噪比", "\(telemetry.wifi.noise.map { "\($0) dBm" } ?? "未知") / \(telemetry.wifi.signalToNoise.map { "\($0) dB" } ?? "未知")")
                        detail("当前连接协议", "\(telemetry.wifi.generation) · \(telemetry.wifi.protocolName)")
                        detail("频段 / 信道", "\(telemetry.wifi.bandGHz.map { $0 == 2 ? "2.4 GHz" : "\($0) GHz" } ?? "未知") / \(telemetry.wifi.channel.map(String.init) ?? "未知")")
                        detail("信道宽度", telemetry.wifi.channelWidthMHz.map { "\($0) MHz" } ?? "系统未提供")
                        detail("链路发送速率", telemetry.wifi.transmitMbps.map { String(format: "%.0f Mbps", $0) } ?? "系统未提供")
                    }
                    Text("信号等级为经验提示，不是完整健康评分。当前连接协议与路由器支持的最高协议可能不同；链路速率不等于公网带宽。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Panel {
                    HStack {
                        Text("主网络与备用候选").font(.headline)
                        Spacer()
                        if telemetry.isScanning { ProgressView().controlSize(.small) }
                        Button("刷新附近网络") { telemetry.scanNearby() }.disabled(telemetry.isScanning || !authorization.isAuthorized)
                    }
                    Text("候选将按此列表顺序尝试；自动恢复开关在“恢复与记录”。只尝试系统已保存的网络，并在连接后验证联网。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("“连接并验证”会实际切换 Wi-Fi，可能短暂中断当前会话；失败时尝试回退原网络。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("手动填写候选 Wi-Fi 名称", text: $manualName)
                        Button("添加备用") {
                            let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty && name != preferences.primaryWiFi { preferences.setBackup(name, enabled: true); manualName = "" }
                        }.disabled(manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(telemetry.scanMessage).font(.caption).foregroundStyle(.secondary)
                    if names.isEmpty { Text("尚无可显示的候选，可手动添加或授权后扫描附近网络。").foregroundStyle(.secondary) }
                    ForEach(names, id: \.self) { name in
                        Divider()
                        HStack(spacing: 12) {
                            Image(systemName: name == telemetry.wifi.name ? "wifi.circle.fill" : "wifi").foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(name).font(.callout.weight(.medium))
                                    if name == telemetry.wifi.name { tag("当前连接", .teal) }
                                    if name == preferences.primaryWiFi { tag("主网络", .indigo) }
                                }
                                Text(source(name)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if name == preferences.primaryWiFi || preferences.backupWiFi.contains(name) {
                                Button("连接并验证") { recovery.connectManually(to: name) }
                                    .disabled(recovery.isBusy || !authorization.isAuthorized || !telemetry.savedNetworks.contains(name))
                            }
                            if name != preferences.primaryWiFi {
                                Button("设为主网络") { preferences.primaryWiFi = name; preferences.setBackup(name, enabled: false) }.font(.caption)
                                Toggle("备用", isOn: Binding(get: { preferences.backupWiFi.contains(name) }, set: { preferences.setBackup(name, enabled: $0) })).toggleStyle(.checkbox)
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }.padding(24)
        }
    }
    private func source(_ name: String) -> String {
        var descriptions: [String] = []
        if telemetry.savedNetworks.contains(name) { descriptions.append("系统已保存") }
        if let nearby = telemetry.nearby.first(where: { $0.name == name }) {
            descriptions.append("扫描时可见\(nearby.rssi < 0 ? " · \(nearby.rssi) dBm" : "")")
            descriptions.append(nearby.capturedAt.formatted(date: .omitted, time: .standard))
        } else { descriptions.append(name == telemetry.wifi.name ? "当前已关联" : "当前范围未验证") }
        return descriptions.joined(separator: " · ")
    }
    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout.monospacedDigit()) }
    }
    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 7).padding(.vertical, 3).foregroundStyle(color).background(color.opacity(0.1), in: Capsule())
    }
}

struct PreferencesPane: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var telemetry: TelemetrySession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Panel {
                    Text("菜单栏显示").font(.headline)
                    Picker("显示内容", selection: $preferences.menuDisplay) { ForEach(MenuDisplay.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    Text("使用当前所选接口的真实收发速率。B/s、KB/s、MB/s 表示字节每秒，和 Wi-Fi 协商速率的 Mbps 不同。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Panel {
                    Text("流量统计接口").font(.headline)
                    Picker("接口", selection: $preferences.interfaceName) {
                        Text("自动选择活跃物理接口").tag("")
                        ForEach(telemetry.interfaces) { Text($0.label).tag($0.name) }
                        if !preferences.interfaceName.isEmpty && !telemetry.interfaces.contains(where: { $0.name == preferences.interfaceName }) {
                            Text("\(preferences.interfaceName) · 当前不可用").tag(preferences.interfaceName)
                        }
                    }
                    Text("当前采样：\(telemetry.interfaceName ?? "未确认")。接口变化或休眠唤醒后重新建立基线；未取得有效样本时显示 —，不当作零流量。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Panel {
                    Text("当前版本的观测范围").font(.headline)
                    Text("网站每轮完成后等待 30 秒；流量约每秒采样，Wi-Fi 详情约每 10 秒刷新。流量包含该接口的公网、局域网与后台通信。")
                    Text("暂停网站监测也暂停自动恢复，实时流量与状态记录继续。探测趋势仅保留当前会话；恢复事件保存在本机。登录启动与公网测速尚未接入。")
                }
            }.padding(24)
        }
    }
}

struct RecoveryPane: View {
    @ObservedObject var recovery: RecoverySession
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var authorization: WiFiAuthorization
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Panel {
                    HStack {
                        Label("网络自动恢复", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Spacer()
                        if recovery.isBusy { ProgressView().controlSize(.small) }
                        Toggle("开启自动恢复", isOn: $preferences.autoRecovery).toggleStyle(.switch)
                    }
                    Text(recovery.title).font(.title3.weight(.semibold))
                    Text(recovery.detail).foregroundStyle(.secondary)
                    Text("持续掉线确认约 3–6 秒后尝试候选。仍关联时每 10 秒复核，3 个独立 TCP 目标连续 2 轮全失败才尝试切换。实际时长还包含系统连接与联网验证。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("仅连接你选定且系统已保存的网络；不自动开启 Wi-Fi，不改变 DNS 或代理，不读取或保存密码。健康时保持当前连接；手动改变网络后等待 60 秒，恢复成功后冷却 120 秒。关闭本开关或暂停网站监测可停止后续请求。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !authorization.isAuthorized { PermissionCard(authorization: authorization) }
                }
                Panel {
                    Text("恢复事件记录").font(.headline)
                    Text("记录观测时间、Wi-Fi 状态、候选尝试及验证结果，保留最近 500 条。应用退出及休眠期间标为观测间隔。TCP 可达与网站响应不能代替实际远程控制会话验收。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("记录保存在本机，重启应用后仍可查看。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("在 Finder 查看记录") { NSWorkspace.shared.activateFileViewerSelecting([recovery.historyURL]) }
                    }
                    if let error = recovery.storageError { Text(error).foregroundStyle(.orange) }
                    ForEach(recovery.events.reversed()) { event in
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: event.kind == "recoveryVerified" ? "checkmark.circle.fill" : "clock.arrow.circlepath").foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.message).font(.callout)
                                Text(event.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                if let wifi = event.wifi {
                                    Text("\(wifi.name ?? "名称未知") · \(wifi.interface ?? "接口未知")\(wifi.rssi.map { " · \($0) dBm" } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let health = event.health {
                                    Text("无线 TCP：\(health.successes) 成功 / \(health.failures) 失败 / \(health.unknown) 未知")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }.padding(24)
        }
    }
}

struct ProcessPane: View {
    @ObservedObject var processes: ProcessTrafficSession
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("软件与进程收发").font(.title3.weight(.semibold))
                    Text("试验性 · 按需采样 · 本页关闭后停止 · 不与网卡总量相加").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if processes.isSampling { ProgressView().controlSize(.small) }
                Button(processes.isRunning ? "停止进程采样" : "开启进程采样") { processes.isRunning ? processes.stop() : processes.start() }
            }
            Text(processes.message).font(.callout).foregroundStyle(.secondary)
            if let date = processes.updatedAt { Text("更新于 \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            if processes.rates.isEmpty {
                ContentUnavailableView("暂无有效进程样本", systemImage: "app.connected.to.app.below.fill", description: Text("开启后读取系统统计。采样受超时保护，失败不会阻塞网站和网速监测。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(processes.rates) {
                    TableColumn("软件 / 进程") { rate in
                        HStack(spacing: 9) {
                            if let icon = NSRunningApplication(processIdentifier: rate.pid)?.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
                            else { Image(systemName: "gearshape.2").frame(width: 24) }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(NSRunningApplication(processIdentifier: rate.pid)?.localizedName ?? rate.name)
                                Text("进程 \(rate.pid) · \(rate.name)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("下载") { Text(TrafficFormat.rate($0.download)).monospacedDigit().foregroundStyle(.teal) }.width(110)
                    TableColumn("上传") { Text(TrafficFormat.rate($0.upload)).monospacedDigit().foregroundStyle(.indigo) }.width(110)
                }
            }
            Text("代理和浏览器辅助进程可能承担其他软件的通信。这里展示系统可观察的进程，未确认的软件归属不会猜测；首次或重置后的速率需要下一次样本。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).onDisappear { processes.stop() }
    }
}
