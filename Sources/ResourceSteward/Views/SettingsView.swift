import ResourceStewardCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

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
                    Text("半自动只会在场景切换时动手，而且只处理打分已经达到建议阈值的离场景应用。VPN/代理（Shadowrocket、Clash、Surge 等）、容器/虚拟机（OrbStack、Docker 等）和菜单栏常驻工具不会冻结。冻结后内存仍由系统自然回收。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("场景匹配") {
                    sliderRow("时间窗口（分钟）", value: windowBinding, range: 3...30, format: "%.0f")
                    sliderRow("未分类阈值", value: thresholdBinding, range: 0.05...0.6, format: "%.2f")
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
                    Button("恢复默认权重", action: coordinator.resetWeights)
                        .controlSize(.small)
                }

                section("能力边界") {
                    Text("本工具不能压缩其他进程的内存页，也不能获取其他进程的 task port。菜单栏里出现的处理动作只有：降低优先级、冻结、退出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("退出管家时会自动解冻，并恢复已降低的优先级。若被强制结束，下次启动也会把上次留下的冻结进程恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("数据只保存在本机 SQLite，无网络上传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("数据库：\(coordinator.store.filePath)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
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
}
