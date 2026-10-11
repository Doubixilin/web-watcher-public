import SwiftUI
import Charts
import WatcherCore

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct MetricCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75).help(value)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .top)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PermissionCard: View {
    @ObservedObject var authorization: WiFiAuthorization
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.circle").font(.title2).foregroundStyle(.teal)
            Text(authorization.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if !authorization.isAuthorized {
                Button("授权读取 Wi-Fi 名称") { authorization.request() }
            }
        }.padding(14).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TrafficChart: View {
    let points: [TrafficPoint]
    var body: some View {
        if points.isEmpty {
            ContentUnavailableView("建立流量基线", systemImage: "chart.xyaxis.line", description: Text("取得连续两个有效样本后显示真实速率。"))
        } else {
            Chart(points) { point in
                LineMark(x: .value("时间", point.date), y: .value("速率", point.download)).foregroundStyle(by: .value("方向", "下载"))
                LineMark(x: .value("时间", point.date), y: .value("速率", point.upload)).foregroundStyle(by: .value("方向", "上传"))
                if points.count == 1 {
                    PointMark(x: .value("时间", point.date), y: .value("速率", point.download)).foregroundStyle(.teal)
                    PointMark(x: .value("时间", point.date), y: .value("速率", point.upload)).foregroundStyle(.indigo)
                }
            }.chartForegroundStyleScale(["下载": Color.teal, "上传": Color.indigo])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(); AxisValueLabel { if let number = value.as(Double.self) { Text(TrafficFormat.rate(number)).font(.caption2) } }
                    }
                }.chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()) } }
        }
    }
}

struct ProbeTrendChart: View {
    let points: [ProbeTrendPoint]
    var body: some View {
        if points.isEmpty {
            ContentUnavailableView("等待探测样本", systemImage: "waveform.path.ecg", description: Text("完成检测后显示当前会话的耗时趋势。"))
        } else {
            Chart(points) { point in
                LineMark(x: .value("时间", point.date), y: .value("总耗时", point.milliseconds)).foregroundStyle(.teal)
                PointMark(x: .value("时间", point.date), y: .value("总耗时", point.milliseconds)).foregroundStyle(point.reachable ? .teal : .orange)
            }.chartYAxisLabel("ms")
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
        }
    }
}

struct ProbeCard: View {
    let target: ProbeTarget
    let result: ProbeResult?
    var body: some View {
        Panel {
            HStack { Text(target.name).font(.headline); Spacer(); Text(result?.headline ?? "等待检测").foregroundStyle(result.map { $0.reachable && $0.meetsExpectation != false ? Color.teal : .orange } ?? .secondary) }
            Text(target.url?.absoluteString ?? "\(target.host)\(target.kind == .tcp ? ":\(target.port)" : "")").font(.caption).foregroundStyle(.secondary)
            if let result {
                HStack(spacing: 22) {
                    ForEach(result.phases, id: \.phase) { phase in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(phaseName(phase.phase)).font(.caption).foregroundStyle(.secondary)
                            Text(phase.milliseconds.map { String(format: "%.1f ms", $0) } ?? (phase.status == .failed ? "未成功" : "耗时未提供")).monospacedDigit()
                        }.help(phase.detail)
                    }
                    Spacer()
                    Text(String(format: "总计 %.1f ms", result.elapsedMS)).font(.callout.monospacedDigit())
                }
                Text(result.detail).font(.callout)
                DisclosureGroup("实际路径与阶段证据") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("配置：\(result.path.configured)")
                        Text("本地：\(result.path.localAddress ?? "未提供") · 接口：\(result.path.localInterface ?? "未确认")")
                        Text("对端：\(result.path.remoteAddress ?? "未提供") · 协议：\(result.path.protocolName ?? "未提供")")
                        Text("HTTP 代理标记：\(result.path.proxyConnection.map { $0 ? "是" : "否" } ?? "未提供 / 不适用")")
                        Text(result.path.note)
                        ForEach(result.phases, id: \.phase) { phase in Text("\(phaseName(phase.phase))：\(phase.detail)") }
                        Text("检测开始：\(result.startedAt.formatted(date: .abbreviated, time: .standard))")
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption)
            }
        }.textSelection(.enabled)
    }
    private func phaseName(_ phase: ProbePhase) -> String {
        switch phase { case .dns: "DNS 解析"; case .connection: "连接建立"; case .tls: "TLS 握手"; case .http: "响应首字节" }
    }
}
