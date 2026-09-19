import ResourceStewardCore
import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var selectedTab: PanelTab = .processes
    @State private var visitedTabs: Set<PanelTab> = [.processes]

    var body: some View {
        Group {
            if coordinator.settings.hasCompletedOnboarding {
                mainPanel
            } else {
                OnboardingView()
            }
        }
        .background(.ultraThinMaterial)
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                tabPane(.processes) { ProcessListView() }
                tabPane(.favorites) { FavoriteAppsView() }
                tabPane(.settings) { SettingsView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(nil, value: selectedTab)
            Divider()
            footer
        }
        .frame(width: Theme.panelWidth, height: Theme.panelHeight)
    }

    private var header: some View {
        VStack(spacing: 10) {
            // Title & Mode Bar
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.pressureColor(coordinator.pressure))
                    Text("资源管家")
                        .font(.system(size: 14, weight: .bold))
                }

                Spacer()

                HStack(spacing: 6) {
                    if coordinator.settings.authorizationLevel == .sceneSwitch {
                        Text("半自动")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    } else {
                        Text("仅建议")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
            }

            // Dashboard Card: Circular Gauge + Resource Bars
            HStack(spacing: 14) {
                // Left: Circular RAM Gauge
                VStack(spacing: 4) {
                    ZStack {
                        // Background track
                        Circle()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 5)
                            .frame(width: 58, height: 58)

                        // Active arc
                        Circle()
                            .trim(from: 0, to: CGFloat(min(1.0, max(0.03, ramPercent / 100.0))))
                            .stroke(
                                Theme.pressureColor(coordinator.pressure),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 58, height: 58)
                            .shadow(color: Theme.pressureColor(coordinator.pressure).opacity(0.25), radius: 3)

                        // Center content
                        VStack(spacing: 0) {
                            Text("RAM")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", ramPercent))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.pressureColor(coordinator.pressure))
                            .frame(width: 5, height: 5)
                        Text(coordinator.pressure.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.pressureColor(coordinator.pressure))
                    }
                }
                .padding(.vertical, 2)

                // Right: CPU, GPU & Memory Stat Bars
                VStack(alignment: .leading, spacing: 7) {
                    MinimalStatBar(
                        title: "CPU",
                        percent: coordinator.hostCPU.usagePercent,
                        detail: String(format: "用户 %.0f%% · 系统 %.0f%%", coordinator.hostCPU.userPercent, coordinator.hostCPU.systemPercent),
                        color: Theme.usageColor(coordinator.hostCPU.usagePercent)
                    )

                    MinimalStatBar(
                        title: "GPU",
                        percent: coordinator.hostGPU.usagePercent,
                        detail: gpuDetail,
                        color: Theme.usageColor(coordinator.hostGPU.usagePercent),
                        available: coordinator.hostGPU.available
                    )

                    MinimalStatBar(
                        title: "内存",
                        percent: ramPercent,
                        detail: memoryDetail,
                        color: Theme.pressureColor(coordinator.pressure)
                    )
                }
            }
            .modernCard(padding: 10)

            // Context Awareness Pill
            HStack(spacing: 6) {
                Image(systemName: coordinator.estimatedReleaseMB > 0 ? "sparkles" : "waveform.path.ecg")
                    .font(.system(size: 10))
                    .foregroundStyle(coordinator.estimatedReleaseMB > 0 ? Color.accentColor : .secondary)

                if coordinator.estimatedReleaseMB > 0 {
                    Text("场景感知 · 发现闲置后台应用，预计可释放 \(ByteFormat.mb(coordinator.estimatedReleaseMB))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary)
                } else {
                    Text(coordinator.autoStatusText.isEmpty ? matchCaption : coordinator.autoStatusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(coordinator.estimatedReleaseMB > 0 ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(coordinator.estimatedReleaseMB > 0 ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.05), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Capsule Tab Switcher
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            tabSelection.wrappedValue = tab
                        }
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()

            Button {
                coordinator.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .help("立即刷新")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color.primary.opacity(0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .help("退出管家（会自动解冻）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var tabSelection: Binding<PanelTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                selectedTab = tab
                guard !visitedTabs.contains(tab) else { return }
                Task { @MainActor in
                    visitedTabs.insert(tab)
                }
            }
        )
    }

    @ViewBuilder
    private func tabPane<Content: View>(_ tab: PanelTab, @ViewBuilder content: () -> Content) -> some View {
        if visitedTabs.contains(tab) {
            content()
                .opacity(selectedTab == tab ? 1 : 0)
                .allowsHitTesting(selectedTab == tab)
                .accessibilityHidden(selectedTab != tab)
                .zIndex(selectedTab == tab ? 1 : 0)
        }
    }

    private var ramPercent: Double {
        guard coordinator.hostMemory.physicalBytes > 0 else { return 0 }
        return Double(coordinator.hostMemory.usedBytes) / Double(coordinator.hostMemory.physicalBytes) * 100.0
    }

    private var memoryDetail: String {
        let used = ByteFormat.string(coordinator.hostMemory.usedBytes)
        let total = ByteFormat.string(coordinator.hostMemory.physicalBytes)
        let compressed = ByteFormat.string(coordinator.hostMemory.compressedBytes)
        return "已用 \(used) / \(total) · 压缩 \(compressed)"
    }

    private var gpuDetail: String {
        guard coordinator.hostGPU.available else { return "当前无法读取" }
        let gpu = coordinator.hostGPU
        let name = gpu.displayName
        if gpu.memoryUsedBytes > 0 || gpu.memoryTotalBytes > 0 {
            let used = ByteFormat.string(gpu.memoryUsedBytes)
            if gpu.memoryTotalBytes > 0 {
                let total = ByteFormat.string(gpu.memoryTotalBytes)
                return "\(name) · \(gpu.memoryKindName) \(used) / \(total)"
            }
            return "\(name) · \(gpu.memoryKindName) \(used)"
        }
        return "\(name) · 引擎占用"
    }

    private var matchCaption: String {
        if coordinator.settings.jevReclaimEnabled {
            return "按系统负载与正在运行的灰区 App 询问 Jev"
        }
        return "启用 Jev 后才会按负载给出建议"
    }
}

private struct MinimalStatBar: View {
    let title: String
    let percent: Double
    var detail: String = ""
    var color: Color
    var available: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(available ? String(format: "%.0f%%", percent) : "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(available ? color : .secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    if available {
                        Capsule()
                            .fill(color)
                            .frame(width: max(3, geo.size.width * CGFloat(min(1.0, max(0.0, percent / 100.0)))))
                    }
                }
            }
            .frame(height: 4)

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
