import ResourceStewardCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var apiKeyDraft: String = ""
    @State private var keyStatus: String = JevKeychain.hasAPIKey ? "已配置（钥匙串）" : "未配置"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("授权级别") {
                    ForEach(AuthorizationLevel.allCases) { level in
                        Button {
                            guard level.isAvailable else { return }
                            coordinator.settings.authorizationLevel = level
                            coordinator.persistSettings()
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: coordinator.settings.authorizationLevel == level
                                      ? "largecircle.fill.circle"
                                      : "circle")
                                    .foregroundStyle(level.isAvailable ? Color.accentColor : Color.secondary)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(level.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(level.isAvailable ? Color.primary : Color.secondary)
                                    Text(level.footnote)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!level.isAvailable)
                    }
                    Text("半自动会在已识别的工作场景里持续处理：空闲约 2 分钟以上、分数达到冻结阈值、且当前没有窗口的离场景应用会被冻结。有窗口的应用（备忘录、浏览器等）不会冻结，否则会卡住屏幕。不必等再切一次场景。降低优先级不再自动执行（几乎无感）。系统守护进程和小组件不会处理。VPN/代理、容器/虚拟机（OrbStack、Docker 等）、菜单栏常驻工具，以及你在「常用」里勾选的应用都不会冻结。冻结后内存仍由系统自然回收。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("场景匹配") {
                    sliderRow("时间窗口（分钟）", value: windowBinding, range: 3...30, format: "%.0f")
                    sliderRow("最低证据（无独有 App 时）", value: thresholdBinding, range: 0.3...1.0, format: "%.2f")
                    Text("只开了 Chrome 这类多个场景都有的软件时，低于此值保持未分类。WebStorm / IntelliJ 这类独有 App 不受这条限制。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow("采样间隔（秒）", value: intervalBinding, range: 2...10, format: "%.0f")
                }

                section("打分权重") {
                    Text("分数 = 空闲/内存/可重启加权后归一化到 0–100，再扣除场景与前台惩罚。前台权重足够让分数归零。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow("空闲 w1", value: weightBinding(\.idle), range: 0...80, format: "%.0f")
                    sliderRow("内存 w2", value: weightBinding(\.memory), range: 0...80, format: "%.0f")
                    sliderRow("可重启 w3", value: weightBinding(\.restartability), range: 0...50, format: "%.0f")
                    sliderRow("场景惩罚 w4", value: weightBinding(\.workspace), range: 0...120, format: "%.0f")
                    sliderRow("前台惩罚 w5", value: weightBinding(\.foreground), range: 100...999, format: "%.0f")
                    sliderRow("离场景加分", value: weightBinding(\.offWorkspace), range: 0...50, format: "%.0f")
                    sliderRow("空闲封顶（分钟）", value: weightBinding(\.idleCapMinutes), range: 15...120, format: "%.0f")
                    sliderRow("内存封顶（MB）", value: weightBinding(\.memoryCapMB), range: 512...8192, format: "%.0f")
                    Button("恢复默认权重", action: coordinator.resetWeights)
                        .controlSize(.small)
                }

                section("Jev 灰区回收（TypeSafe）") {
                    Toggle("启用 Jev 灰区判断", isOn: jevEnabledBinding)
                    Text("默认关闭。开启且配置 API Key 后，仅对通过本地硬门禁的第三方灰区候选调用 TypeSafe Jev；会议/IM/辅助功能/有窗口/常用等本地拒绝项绝不会被覆盖。失败或不确定时按不处理（fail-closed）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Base URL（默认 https://api.typesafe.ai）", text: jevBaseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("可填主机根地址或完整 `/v1/systemone` URL；用于官方 API、OpenRouter 兼容网关或自建代理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("模型名（默认 jev-latest）", text: jevModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("官方可用 `jev-latest`；经 OpenRouter / AI Gateway 时填对应 id，例如 `typesafe-ai/jev`。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("API Key（TypeSafe / OpenRouter）", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    HStack {
                        Button("保存到钥匙串") {
                            do {
                                try JevKeychain.saveAPIKey(apiKeyDraft)
                                keyStatus = JevKeychain.hasAPIKey ? "已保存（钥匙串）" : "未配置"
                            } catch {
                                keyStatus = error.localizedDescription
                            }
                        }
                        .controlSize(.small)
                        Button("清除 Key") {
                            _ = JevKeychain.deleteAPIKey()
                            apiKeyDraft = ""
                            keyStatus = "未配置"
                        }
                        .controlSize(.small)
                        Spacer()
                        Text(keyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("日志子系统：\(JevLog.subsystem)（Console.app 可筛选）。API Key 不会写入日志或 SQLite。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("能力边界") {
                    Text("本工具不能压缩其他进程的内存页，也不能获取其他进程的 task port。菜单栏里出现的处理动作只有：降低优先级、冻结、退出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("退出管家时会自动解冻，并恢复已降低的优先级。若被强制结束，下次启动也会把上次留下的冻结进程恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("默认仅本机 SQLite。启用 Jev 时会向所配置 Base URL 的 `/v1/systemone` 发送灰区候选结构化状态（不含 API Key）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("数据库：\(coordinator.store.filePath)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .onAppear {
                keyStatus = JevKeychain.hasAPIKey ? "已配置（钥匙串）" : "未配置"
                if apiKeyDraft.isEmpty, JevKeychain.hasAPIKey {
                    apiKeyDraft = ""
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var windowBinding: Binding<Double> {
        Binding(
            get: { coordinator.settings.matchingWindowMinutes },
            set: {
                coordinator.settings.matchingWindowMinutes = $0
                coordinator.persistSettings()
            }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { coordinator.settings.matchingThreshold },
            set: {
                coordinator.settings.matchingThreshold = $0
                coordinator.persistSettings()
            }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { coordinator.settings.sampleIntervalSeconds },
            set: {
                coordinator.settings.sampleIntervalSeconds = $0
                coordinator.persistSettings()
            }
        )
    }

    private func weightBinding(_ keyPath: WritableKeyPath<ScoreWeights, Double>) -> Binding<Double> {
        Binding(
            get: { coordinator.settings.weights[keyPath: keyPath] },
            set: {
                coordinator.settings.weights[keyPath: keyPath] = $0
                coordinator.persistSettings()
                coordinator.refresh()
            }
        )
    }


    private var jevBaseURLBinding: Binding<String> {
        Binding(
            get: { coordinator.settings.jevBaseURL },
            set: {
                coordinator.settings.jevBaseURL = $0
                coordinator.persistSettings()
            }
        )
    }

    private var jevModelBinding: Binding<String> {
        Binding(
            get: { coordinator.settings.jevModel },
            set: {
                coordinator.settings.jevModel = $0
                coordinator.persistSettings()
            }
        )
    }

    private var jevEnabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.jevReclaimEnabled },
            set: {
                coordinator.settings.jevReclaimEnabled = $0
                coordinator.persistSettings()
            }
        )
    }
}
