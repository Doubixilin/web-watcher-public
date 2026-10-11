# 本地网络健康软件开源项目调研

核验日期：2026 年 10 月 6 日

## 结论

成熟的网站与服务监测项目可以提供检测协议、成功条件、历史和通知的参考；原生 Mac 项目可以提供菜单栏、网络信息和应用生命周期的参考。本次筛选没有核实到能够完整覆盖“原生 Mac 界面、多网站检测、网络健康分析、自动切换 Wi-Fi”的成熟现成项目。

优先深入 Gatus 的检测设计、MeOrThem 的产品组织和 Stats 的原生应用结构。直接复用或 fork 哪一个项目，应在下一阶段检查代码耦合、许可证、macOS 权限及打包成本后决定。

以下维护数据来自本次读取的 GitHub 官方仓库元数据和最新正式发布记录。Star 数和更新时间属于当日快照；项目年龄、发布与社区规模只帮助评估成熟度，不证明当前 Mac 上的兼容性或无人值守可靠性。候选软件尚未在本机安装测试。

## 重点项目

| 项目 | 起始年份与当日 Star | 最近正式版本 | 许可证 | 参考价值与限制 |
| --- | --- | --- | --- | --- |
| [Gatus](https://github.com/TwiN/gatus) | 2019，12,247 | [v5.37.0，2026-09-24](https://github.com/TwiN/gatus/releases/tag/v5.37.0) | Apache-2.0 | Go 检测引擎与 Web 状态页。支持 HTTP、ICMP、TCP、DNS 和条件判定；不是原生 Mac 应用，也未核实具备本项目需要的 Wi-Fi 自动切换 |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | 2021，92,151 | [2.5.5，2026-09-16](https://github.com/louislam/uptime-kuma/releases/tag/2.5.5) | MIT | 网站管理、状态历史、通知、代理与界面设计成熟度较高。Node.js 与 Web 架构；官方非 Docker 支持列表未列 macOS |
| [Stats](https://github.com/exelban/stats) | 2019，42,330 | [v3.0.20，2026-10-04](https://github.com/exelban/stats/releases/tag/v3.0.20) | MIT | 原生 Mac 菜单栏、系统指标、网络流量、设置与模块组织；多网站主动检测与恢复需另行设计 |
| [MeOrThem](https://github.com/kanzie/meorthem) | 2026，3 | [v2.64.2，2026-08-26](https://github.com/kanzie/meorthem/releases/tag/v2.64.2) | MIT | 多目标探测、网关对照、DNS、网络历史与本地 SQLite，产品形态最接近。项目新、社区小，不能当作已经验证的恢复基础 |
| [WiFi Lens](https://github.com/ShiinaLabs/wifi-lens) | 2026，118 | [v1.6.0，2026-09-05](https://github.com/ShiinaLabs/wifi-lens/releases/tag/v1.6.0) | Apache-2.0 | 原生 Wi-Fi 信息、信道、信号与路径诊断。开源版不包含 Pro 的持续监测、事件历史、历史统计与菜单栏监测 |
| [Sniffnet](https://github.com/GyulyVGC/sniffnet) | 2022，41,344 | [v1.5.1，2026-07-22](https://github.com/GyulyVGC/sniffnet/releases/tag/v1.5.1) | Apache-2.0 | Rust 桌面流量与连接可视化，有 Apple Silicon 安装包。主要观察已有流量，不能代替主动网站健康检测 |
| [PingBar](https://github.com/jedisct1/pingbar) | 2025，77 | [v1.2.0，2026-03-14](https://github.com/jedisct1/pingbar/releases/tag/v1.2.0) | MIT | Swift 与 AppKit 的简洁菜单栏参考。检测指标需按实际实现重新定义，不能直接沿用“Ping”与“Packet Loss”名称 |

Gatus 原仓库地址 `TwinProduction/gatus` 已重定向到 `TwiN/gatus`，后续使用新地址。

## 部分源码发现

### PingBar 的探测指标

[PingManager.swift](https://github.com/jedisct1/pingbar/blob/main/Sources/PingManager.swift) 使用 URLSession 发送 HTTP HEAD 请求，并根据请求错误统计所谓 Packet Loss。它能观察请求连通性，但不能把这个结果直接当作 ICMP 丢包率。

Web Watcher 应分别保存传输层探测与 HTTP 请求的结果，并用准确的名称展示。PingBar 的菜单栏和生命周期可参考，检测语义需要自行设计。

### MeOrThem 的 HTTP 成功条件

[HTTPProber.swift](https://github.com/kanzie/meorthem/blob/main/Sources/MeOrThemCore/Monitoring/HTTPProber.swift) 将 HTTP 4xx 和 5xx 计为失败。对于应用可用性，这可以是一种目标规则；对于本机出口恢复，它不足以证明上游断网。

[MonitoringEngine.swift](https://github.com/kanzie/meorthem/blob/main/Sources/MeOrThemCore/Monitoring/MonitoringEngine.swift) 展示了多目标、网关、DNS 等探测的组织方式。诊断推断及其适用网络仍需逐项核对；尤其不能把不同 DNS 返回不同 CDN 地址、或代理使用合成地址，直接判定为劫持。

### WiFi Lens 的版本边界

[官方 README 的版本比较](https://github.com/ShiinaLabs/wifi-lens#open-source-edition) 明确区分开源版和 Pro。持续监测、事件历史、历史统计等属于 Pro，不能把产品网站展示的所有能力都记录为可复用的开源能力。

### macOS Wi-Fi 信息与权限

[Apple 开发者说明](https://developer.apple.com/forums/thread/759044) 指出，SSID 和 BSSID 信息受定位权限约束，系统 daemon 无法直接取得该权限。

软件应使用支持的接口，事先处理权限，并在信息不可读时显示能力受限。当前网络名称不能读出，不等于网络已断开。

## 补充候选

| 项目 | 当日状态 | 用途 |
| --- | --- | --- |
| [Vigil](https://github.com/SID-Technologies/Vigil) | 2026 年建立，2 Star，v0.1.2 发布于 2026-05-22，Apache-2.0 | Go、Tauri、React、SQLite 的跨平台参考，有 Ping、DNS、STUN 与故障时间线；处于早期阶段 |
| [Mojo Pulse](https://github.com/NativeMojo/mojo-pulse) | 2026 年建立，6 Star，v1.22.1 发布于 2026-08-14，Apache-2.0 | 原生 Mac 健康状态、网络诊断与界面参考；不作为成熟项目的主要依据 |
| [netmon](https://github.com/decoded-cipher/netmon) | 2026 年建立，9 Star，v1.2.0 发布于 2026-04-02，MIT | 网络质量与历史仪表盘参考，有 macOS 发布包；社区与维护历史较短 |

Vigil 的 [macOS Wi-Fi 采集源码](https://github.com/SID-Technologies/Vigil/blob/main/internal/netinfo/wifi_darwin.go) 依赖 system_profiler 输出。该方法在本机可能隐藏网络标识，因此“支持 macOS”与“能够读取所需 Wi-Fi 信息”需要分别验证。

## 参考方式

1. 从 Gatus 借鉴不同协议、成功条件、超时、连续失败与恢复判定。
2. 从 MeOrThem 借鉴网络总览、历史、网关与公网对照及本地存储组织。
3. 从 Stats 借鉴成熟的原生 Mac 软件结构和菜单栏交互。
4. 从 WiFi Lens 借鉴受权限约束的 Wi-Fi 信息获取与诊断体验。
5. 将流量抓包、全进程带宽分析和跨平台架构留到有明确需求时再考虑。

优先参考设计，暂不决定大规模复制代码或组合运行多个项目。自动网络恢复需要针对当前 macOS 和实际远程控制路径单独实现与验收。

## 来源与核验方式

- 项目官方 GitHub 仓库的 README、许可证、发布记录与仓库元数据。
- GitHub 官方 API：`GET /repos/{owner}/{repo}` 与 `GET /repos/{owner}/{repo}/releases/latest`。
- 上文列出的探测源码为有限范围检查，不代表完整代码审计。链接指向可变分支；实际复用前需要记录固定 commit。
- 私人网络观察与原始运行材料仅保存在本地，不随调研文档公开；通用使用场景见需求文档。历史材料不作为当前网络状态的证明。
