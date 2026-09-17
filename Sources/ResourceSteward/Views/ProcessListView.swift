import ResourceStewardCore
import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var expandedID: String?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            if let message = coordinator.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(coordinator.lastMessageIsError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(coordinator.lastMessageIsError ? Color.red.opacity(0.08) : Color.primary.opacity(0.04))
            }

            if coordinator.estimatedReleaseMB > 0 {
                HStack {
                    Text("预计可释放 \(ByteFormat.mb(coordinator.estimatedReleaseMB))")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text("估算 · 非直接回收")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            if !coordinator.frozen.isEmpty {
                frozenSection
            }

            HStack {
                Text("按可处理分数排序")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("只看建议", isOn: actionableBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            TextField("筛选名称，例如 Chrome", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)

            if displayedGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(emptyListText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayedGroups) { group in
                            ProcessGroupRow(group: group, expanded: expandedID == group.id)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    expandedID = expandedID == group.id ? nil : group.id
                                }
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
        }
    }

    private var displayedGroups: [ProcessGroupViewModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = needle.isEmpty ? coordinator.visibleGroups : coordinator.processGroups
        guard !needle.isEmpty else { return source }
        return source.filter { group in
            group.displayName.lowercased().contains(needle)
                || group.key.lowercased().contains(needle)
                || group.members.contains { member in
                    member.snapshot.processName.lowercased().contains(needle)
                        || (member.snapshot.bundleID?.lowercased().contains(needle) ?? false)
                }
        }
    }

    private var emptyListText: String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return "没有匹配「\(needle)」的进程"
        }
        if coordinator.settings.showOnlyActionable {
            return "没有达到冻结/降优先级阈值的用户应用。场景内、前台、常用和系统进程不会出现在这里。关掉「只看建议」可看全部。"
        }
        return "正在采集进程…"
    }

    private var actionableBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.showOnlyActionable },
            set: {
                coordinator.settings.showOnlyActionable = $0
                coordinator.persistSettings()
            }
        )
    }

    private var frozenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已冻结")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
            Text("退出管家时会自动解冻。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            ForEach(coordinator.frozen) { item in
                HStack {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(Theme.actionColor(.freeze))
                    Text(item.processName)
                        .font(.caption)
                    Text("PID \(item.pid)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复") {
                        coordinator.thaw(pid: item.pid)
                    }
                    .controlSize(.mini)
                }
                .padding(.horizontal, 14)
            }
            Divider()
        }
        .padding(.bottom, 4)
    }
}

private struct ProcessGroupRow: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let group: ProcessGroupViewModel
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                AppIconView(path: group.appPath)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if group.isForeground {
                            Text("前台")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.18), in: Capsule())
                        }
                        if group.score.isInCurrentWorkspace {
                            Text("场景内")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                        }
                        if group.isKeepAlive {
                            Text("常驻")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.16), in: Capsule())
                        } else if coordinator.isFavorite(group) {
                            Text("常用")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.16), in: Capsule())
                        }
                        if group.members.count > 1 {
                            Text(group.companionCount > 0
                                 ? "\(group.members.count) 个进程 · 含 Helper"
                                 : "\(group.members.count) 个进程")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(ByteFormat.mb(group.totalMemoryMB))  ·  CPU \(Int(group.cpuPercent))%  ·  \(DurationFormat.idle(group.idleSeconds))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(String(format: "%.0f", group.score.score))
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.scoreColor(group.score.score))
                    .frame(width: 32, alignment: .trailing)
            }

            HStack {
                Text(statusTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.actionColor(statusAction))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.actionColor(statusAction).opacity(0.14), in: Capsule())
                Spacer()
                if group.appliedAction == .freeze {
                    Button("恢复") {
                        for member in group.members {
                            coordinator.thaw(pid: member.snapshot.pid)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else if group.appliedAction == .throttle {
                    Button("恢复优先级") {
                        coordinator.restorePriority(for: group)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else if group.effectiveSuggestion != .none {
                    Button("应用建议") {
                        coordinator.request(group.effectiveSuggestion, for: group)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(group.isForeground || group.isProtected)
                }
            }

            if expanded {
                ScoreBreakdownView(components: group.score.components, estimatedMB: group.members.map(\.snapshot.memoryFootprintMB).max() ?? 0)
                if group.members.count > 1 {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(group.members) { member in
                            HStack(spacing: 6) {
                                Text("PID \(member.snapshot.pid)  \(member.snapshot.processName)  \(ByteFormat.mb(member.snapshot.memoryFootprintMB))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let role = ProcessFamily.roleLabel(
                                    bundleID: member.snapshot.bundleID,
                                    processName: member.snapshot.processName
                                ) {
                                    Text(role)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                HStack {
                    if group.appliedAction != .freeze {
                        ForEach(alternateActions, id: \.rawValue) { action in
                            Button(action.title) {
                                coordinator.request(action, for: group)
                            }
                            .controlSize(.mini)
                            .disabled(group.isForeground || group.isProtected)
                        }
                    }
                    Spacer()
                    if canMarkFavorite {
                        Button(coordinator.isFavorite(group) ? "取消常用" : "设为常用") {
                            coordinator.toggleFavorite(group)
                        }
                        .controlSize(.mini)
                    }
                    Button("不再建议") {
                        coordinator.ignoreAndBlacklist(group)
                    }
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var canMarkFavorite: Bool {
        guard !group.isKeepAlive else { return false }
        let bundleID = ProcessFamily.rootBundleID(from: group.primary.snapshot.bundleID)
            ?? group.primary.snapshot.bundleID
            ?? ""
        return !bundleID.isEmpty && !bundleID.hasPrefix("pid:")
    }

    private var alternateActions: [SuggestedAction] {
        SuggestedAction.allCases.filter { $0 != .none && $0 != group.effectiveSuggestion }
    }

    private var statusAction: SuggestedAction {
        group.appliedAction ?? group.effectiveSuggestion
    }

    private var statusTitle: String {
        switch group.appliedAction {
        case .freeze: return "已冻结"
        case .throttle: return "已降低优先级"
        default: return group.effectiveSuggestion.title
        }
    }
}

private struct ScoreBreakdownView: View {
    let components: ScoreComponents
    let estimatedMB: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(components.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.caption2)
                        .frame(width: 52, alignment: .leading)
                    GeometryReader { geo in
                        let width = geo.size.width * min(1, abs(item.value) / 100)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.isPenalty ? Color.red.opacity(0.45) : Color.accentColor.opacity(0.55))
                            .frame(width: max(width, item.value == 0 ? 0 : 2), height: 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 6)
                    Text(String(format: "%+.1f", item.value))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(item.isPenalty ? .red : .secondary)
                }
            }
            Text("预计占用 \(ByteFormat.mb(estimatedMB))，处理后由系统决定是否回收")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
