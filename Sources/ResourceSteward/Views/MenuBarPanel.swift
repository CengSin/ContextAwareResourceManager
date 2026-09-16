import ResourceStewardCore
import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var selectedTab: PanelTab = .processes
    @State private var visitedTabs: Set<PanelTab> = [.processes]

    var body: some View {
        ZStack {
            Group {
                if coordinator.settings.hasCompletedOnboarding {
                    mainPanel
                } else {
                    OnboardingView()
                }
            }
            if let pending = coordinator.pendingAction {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                ConfirmActionCard(pending: pending)
                    .padding(18)
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
                tabPane(.workspaces) { WorkspaceEditorView() }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("场景资源管家")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.pressureColor(coordinator.pressure))
                            .frame(width: 8, height: 8)
                        Text("内存压力 \(coordinator.pressure.title)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.pressureColor(coordinator.pressure))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        if coordinator.settings.authorizationLevel == .sceneSwitch {
                            Text("半自动")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                        }
                        Text(coordinator.match.displayName)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(matchCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                UsageStat(
                    title: "CPU",
                    percent: coordinator.hostCPU.usagePercent,
                    detail: String(format: "用户 %.0f%%  系统 %.0f%%", coordinator.hostCPU.userPercent, coordinator.hostCPU.systemPercent)
                )
                UsageStat(
                    title: "GPU",
                    percent: coordinator.hostGPU.usagePercent,
                    detail: gpuDetail,
                    available: coordinator.hostGPU.available
                )
            }

            HStack(spacing: 8) {
                MemoryStat(title: "RAM", value: ramValue)
                MemoryStat(title: "Compressed", value: ByteFormat.string(coordinator.hostMemory.compressedBytes))
                MemoryStat(title: "Swap", value: ByteFormat.string(coordinator.hostMemory.swapUsedBytes))
            }

            Text("冻结或退出后，内存由系统自然回收。下列「预计」不是本工具直接压缩的结果。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Picker("", selection: tabSelection) {
                ForEach(PanelTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                coordinator.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("退出场景管家（会自动解冻）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var tabSelection: Binding<PanelTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                selectedTab = tab
                guard !visitedTabs.contains(tab) else { return }
                // Mount the destination tab on the next turn so the segmented
                // control can paint before the new page is built.
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

    private var ramValue: String {
        let used = ByteFormat.string(coordinator.hostMemory.usedBytes)
        let total = ByteFormat.string(coordinator.hostMemory.physicalBytes)
        return "\(used) / \(total)"
    }

    private var gpuDetail: String {
        guard coordinator.hostGPU.available else { return "当前无法读取" }
        let name = coordinator.hostGPU.displayName
        if coordinator.hostGPU.memoryTotalBytes > 0 {
            let used = ByteFormat.string(coordinator.hostGPU.memoryUsedBytes)
            let total = ByteFormat.string(coordinator.hostGPU.memoryTotalBytes)
            if name.contains("Intel") {
                return "\(name)  共享显存 \(used) / \(total)"
            }
            return "\(name)  显存 \(used) / \(total)"
        }
        return "\(name)  引擎占用"
    }

    private var matchCaption: String {
        if coordinator.match.isUnclassified {
            if coordinator.workspaces.isEmpty {
                return "先在「场景」里定义工作场景"
            }
            return String(format: "证据 %.1f，不足以定性", coordinator.match.similarity)
        }
        if let top = coordinator.forecasts.first, coordinator.forecastSampleCount >= 3, top.probability >= 0.2 {
            return String(
                format: "证据 %.1f · 此时常切到「%@」",
                coordinator.match.similarity,
                top.name
            )
        }
        return String(format: "证据 %.1f · %d 个近期 App", coordinator.match.similarity, coordinator.match.activeBundleIDs.count)
    }
}

private struct ConfirmActionCard: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let pending: PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.action.confirmationTitle)
                .font(.headline)
            Text("\(pending.group.displayName) · \(pending.group.members.count) 个进程")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if pending.group.companionCount > 0 {
                Text("Helper / Renderer 会随主应用一起处理，不会单独降级。单独处理它们会让开链接等功能失效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(pending.action.confirmationDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消", action: coordinator.cancelPending)
                Spacer()
                Button("确认执行", action: coordinator.confirmPending)
                    .buttonStyle(.borderedProminent)
                    .tint(pending.action == .quit ? .red : .accentColor)
            }
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

private struct UsageStat: View {
    let title: String
    let percent: Double
    var detail: String = ""
    var available: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(available ? String(format: "%.0f%%", percent) : "—")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(available ? Theme.usageColor(percent) : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    if available {
                        Capsule()
                            .fill(Theme.usageColor(percent))
                            .frame(width: max(4, geo.size.width * CGFloat(min(1, percent / 100))))
                    }
                }
            }
            .frame(height: 6)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MemoryStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
