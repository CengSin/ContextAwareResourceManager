import ResourceStewardCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var apiKeyDraft: String = ""
    @State private var keyStatus: String = JevAPIKey.statusDescription()

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
                    Text("Level 0 会弹出独立确认窗口，确认后才执行。Level 1 自动执行，完成后发系统通知（需授权通知权限）。前台、VPN/会议/IM、常用和系统进程不会进灰区。没有冻结。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow("采样间隔（秒）", value: intervalBinding, range: 2...10, format: "%.0f")
                }

                section("Jev 灰区回收（TypeSafe）") {
                    Toggle("启用 Jev 灰区判断", isOn: jevEnabledBinding)
                    Text("开启且配置 API Key 后，把当前系统负载和正在运行的灰区 App 一次交给 Jev，对每个 App 选择保留、降低优先级或退出。会议/IM/辅助功能/常用等本地拒绝项不会进名单。失败或不确定时全部保留（fail-closed）。退出要求更高置信度（≥0.85）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Base URL（默认 https://api.typesafe.ai）", text: jevBaseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("可填主机根（默认拼 `/v1/systemone`），或完整 endpoint：TypeSafe `/v1/systemone`、OpenRouter `https://openrouter.ai/api/alpha/decisions`。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("模型名（默认 jev-latest）", text: jevModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("TypeSafe 官方可用 `jev-latest`；OpenRouter Decisions 示例为 `~typesafe/jev-latest`（含前导 `~`）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("优先读环境变量 `\(JevAPIKey.environmentVariable)`；也可写在 `~/Library/Application Support/ResourceSteward/env`（一行 KEY=VALUE）。菜单栏 App 读不到 shell 的 export 时用 env 文件最省事。钥匙串仅作回退（adhoc 重签易丢）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("API Key（TypeSafe / OpenRouter）", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    HStack {
                        Button("保存到钥匙串") {
                            do {
                                try JevKeychain.saveAPIKey(apiKeyDraft)
                                keyStatus = JevAPIKey.statusDescription()
                            } catch {
                                keyStatus = error.localizedDescription
                            }
                        }
                        .controlSize(.small)
                        Button("清除 Key") {
                            _ = JevKeychain.deleteAPIKey()
                            apiKeyDraft = ""
                            keyStatus = JevAPIKey.statusDescription()
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
                    Text("本工具不能压缩其他进程的内存页，也不能获取其他进程的 task port。菜单栏里出现的处理动作只有：降低优先级、退出。冻结已停用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("降低优先级使用可撤销的后台调度策略，同时降低 CPU、磁盘和网络优先级，不修改 nice。退出管家时会撤销本工具设置的后台策略，并解冻旧版本留下的冻结进程。")
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
                keyStatus = JevAPIKey.statusDescription()
                if apiKeyDraft.isEmpty, JevAPIKey.hasAPIKey {
                    apiKeyDraft = ""
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .modernCard(padding: 10)
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

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { coordinator.settings.sampleIntervalSeconds },
            set: {
                coordinator.settings.sampleIntervalSeconds = $0
                coordinator.persistSettings()
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
