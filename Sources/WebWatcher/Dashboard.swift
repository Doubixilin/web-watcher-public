import SwiftUI
import Charts
import AppKit
import WatcherCore

enum DashboardPage: String, CaseIterable, Identifiable {
    case overview = "总览", sites = "网站检测", wifi = "Wi-Fi 与候选", recovery = "恢复与记录", processes = "进程流量", settings = "显示设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: "square.grid.2x2"; case .sites: "globe"; case .wifi: "wifi"; case .recovery: "arrow.triangle.2.circlepath"; case .processes: "app.connected.to.app.below.fill"; case .settings: "slider.horizontal.3" }
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: MonitorSession
    @ObservedObject var telemetry: TelemetrySession
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var authorization: WiFiAuthorization
    @ObservedObject var processes: ProcessTrafficSession
    @ObservedObject var recovery: RecoverySession
    @State private var page = DashboardPage.overview
    @State private var trendTarget = ProbeTarget.defaults[0].id

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "network").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Web Watcher").font(.headline)
                        Text("本机网络观察").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 10)
                VStack(spacing: 6) {
                    ForEach(DashboardPage.allCases) { entry in
                        Button { page = entry } label: {
                            Label(entry.rawValue, systemImage: entry.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                                .foregroundStyle(page == entry ? Color.teal : Color.primary)
                                .background(page == entry ? Color.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Label(monitor.isRunning ? "网站监测运行中" : "网站监测已暂停", systemImage: monitor.isRunning ? "circle.fill" : "pause.circle")
                    .font(.caption).foregroundStyle(monitor.isRunning ? .teal : .secondary)
                Text("关闭窗口后仍可从菜单栏打开。退出软件会停止全部采样。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(width: 190).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.rawValue).font(.title2.weight(.semibold))
                        Text("\(preferences.autoRecovery ? "自动恢复已开启" : "观察与故障记录") · 流量与网站连通性分别测量").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if monitor.isProbing { ProgressView().controlSize(.small) }
                    Button("立即检测") { monitor.checkNow() }.disabled(monitor.isProbing)
                    Button(monitor.isRunning ? "暂停网站监测" : "继续网站监测") { monitor.isRunning ? monitor.pause() : monitor.start() }
                        .disabled(!monitor.isRunning && monitor.isProbing)
                }.padding(24)
                Divider()
                switch page {
                case .overview: overview
                case .sites: ScrollView { VStack(alignment: .leading, spacing: 14) { assessment; ForEach(monitor.targets) { target in ProbeCard(target: target, result: monitor.results.first { $0.id == target.id }) } }.padding(24) }
                case .wifi: WiFiPane(telemetry: telemetry, preferences: preferences, authorization: authorization, recovery: recovery)
                case .recovery: RecoveryPane(recovery: recovery, preferences: preferences, authorization: authorization)
                case .processes: ProcessPane(processes: processes)
                case .settings: PreferencesPane(preferences: preferences, telemetry: telemetry)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    MetricCard(title: "当前 Wi-Fi", symbol: "wifi", value: telemetry.wifi.name ?? (authorization.isAuthorized ? "名称未提供" : "名称待授权"), detail: "\(telemetry.wifi.generation) · \(telemetry.wifi.bandGHz.map { $0 == 2 ? "2.4 GHz" : "\($0) GHz" } ?? "频段未知")")
                    MetricCard(title: "无线质量", symbol: "antenna.radiowaves.left.and.right", value: telemetry.wifi.rssi.map { "\($0) dBm" } ?? "—", detail: telemetry.wifi.signalLabel)
                    MetricCard(title: "互联网观测", symbol: "globe", value: healthTitle, detail: "依据当前配置目标")
                    MetricCard(title: "Wi-Fi 协商速率", symbol: "speedometer", value: telemetry.wifi.transmitMbps.map { String(format: "%.0f Mbps", $0) } ?? "—", detail: "链路发送速率 · 并非公网测速")
                }
                if telemetry.wifi.name == nil { PermissionCard(authorization: authorization) }
                Panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("实时上下行").font(.headline)
                            Text("流量接口 \(telemetry.interfaceName ?? "未确认") · 物理接口收发，不叠加隧道流量").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        rate("下载", telemetry.latest?.download, color: .teal)
                        rate("上传", telemetry.latest?.upload, color: .indigo)
                    }
                    TrafficChart(points: telemetry.history).frame(height: 180)
                }
                Panel {
                    HStack {
                        Text("探测耗时趋势").font(.headline)
                        Spacer()
                        Picker("目标", selection: $trendTarget) { ForEach(monitor.targets) { Text($0.name).tag($0.id) } }.labelsHidden().frame(width: 180)
                    }
                    ProbeTrendChart(points: monitor.trends.filter { $0.targetID == trendTarget }).frame(height: 150)
                    Text("显示当前会话的探测总耗时；橙色点表示未成功，不能当作网络往返延迟。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                assessment
                Panel {
                    HStack { Label(recovery.title, systemImage: "arrow.triangle.2.circlepath").font(.headline); Spacer(); Button("恢复与记录") { page = .recovery } }
                    Text(recovery.detail).font(.callout).foregroundStyle(.secondary)
                }
                HStack { Text("网站与服务").font(.headline); Spacer(); Button("查看检测详情") { page = .sites } }
                ForEach(monitor.results) { result in
                    HStack(spacing: 12) {
                        Image(systemName: result.reachable && result.meetsExpectation != false ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(result.reachable && result.meetsExpectation != false ? .teal : .orange)
                        VStack(alignment: .leading, spacing: 3) { Text(result.target.name); Text(result.headline).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(String(format: "%.1f ms", result.elapsedMS)).monospacedDigit().foregroundStyle(.secondary)
                    }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("趋势暂保留在当前会话内；完整历史与公网测速尚未接入。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
    private var healthTitle: String {
        if monitor.results.isEmpty { return "等待检测" }
        if monitor.results.allSatisfy(\.reachable) { return "目标可达" }
        return monitor.results.contains(where: \.reachable) ? "部分异常" : "证据不足"
    }
    private var assessment: some View {
        Panel {
            Text(monitor.assessment.title).font(.headline)
            Text(monitor.assessment.detail).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("已完成 \(monitor.completedRounds) 轮")
                if let next = monitor.nextCheckAt { Text("下次 \(next.formatted(date: .omitted, time: .standard))") }
            }.font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("系统路径与环境") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("系统主接口：\(monitor.environment.primaryInterface ?? "未提供") · 网关：\(monitor.environment.router ?? "未提供")")
                    Text("DNS：\(monitor.environment.dnsServers.joined(separator: "、"))")
                    Text("代理：\(monitor.environment.proxySummary)")
                    Text("系统主接口、物理流量接口和网站实际连接路径可能不同。")
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.font(.caption)
        }
    }
    private func rate(_ title: String, _ value: Double?, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(TrafficFormat.rate(value)).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(color) }
    }
}
