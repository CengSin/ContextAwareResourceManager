import ResourceStewardCore
import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var expandedID: String?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            
            if let message = coordinator.lastMessage {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.lastMessageIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundStyle(coordinator.lastMessageIsError ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(coordinator.lastMessageIsError ? Color.red.opacity(0.1) : Color.primary.opacity(0.04))
                )
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }

            
            if !coordinator.frozen.isEmpty {
                frozenSection
            }

            
            HStack(spacing: 8) {
                
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("搜索应用或进程...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )

                
                Toggle(isOn: actionableBinding) {
                    Text("只看建议")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.horizontal, 14)

            
            if displayedGroups.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: query.isEmpty ? "sparkles" : "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text(emptyListText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(displayedGroups) { group in
                            ProcessGroupRow(
                                group: group,
                                expanded: expandedID == group.id,
                                isFavorite: coordinator.isFavorite(group)
                            )
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    expandedID = expandedID == group.id ? nil : group.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
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
            return "没有找到匹配「\(needle)」的进程"
        }
        if coordinator.settings.showOnlyActionable {
            return "当前没有建议降级或退出的应用。\n前台、常用与系统进程已受保护。关掉「只看建议」可查看全部运行应用。"
        }
        return "正在采集进程状态…"
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
            Text("旧版本留下的冻结进程")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
            Text("冻结已停用。请恢复这些进程，退出管家时也会自动解冻。")
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

private struct ProcessGroupRow: View, Equatable {
    @EnvironmentObject private var coordinator: AppCoordinator
    let group: ProcessGroupViewModel
    let expanded: Bool
    let isFavorite: Bool
    @State private var isHovered = false

    nonisolated static func == (lhs: ProcessGroupRow, rhs: ProcessGroupRow) -> Bool {
        lhs.expanded == rhs.expanded
            && lhs.isFavorite == rhs.isFavorite
            && lhs.group == rhs.group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            
            HStack(alignment: .center, spacing: 10) {
                AppIconView(
                    path: group.appPath,
                    bundleID: group.primary.snapshot.bundleID,
                    processName: group.displayName,
                    size: 28
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)

                        if group.isForeground {
                            Text("前台")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.foregroundColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.foregroundColor.opacity(0.14), in: Capsule())
                        }
                        if group.isKeepAlive {
                            Text("常驻")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.favoriteColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.favoriteColor.opacity(0.14), in: Capsule())
                        } else if isFavorite {
                            Text("常用")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.favoriteColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.favoriteColor.opacity(0.14), in: Capsule())
                        }
                        if group.members.count > 1 {
                            Text(group.companionCount > 0 ? "\(group.members.count) 进程 · Helper" : "\(group.members.count) 进程")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.04), in: Capsule())
                        }
                    }

                    
                    HStack(spacing: 6) {
                        Text(ByteFormat.mb(group.totalMemoryMB))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .monospacedDigit()

                        Text("·")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)

                        Text("CPU \(Int(group.cpuPercent))%")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Text("·")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)

                        Text(DurationFormat.idle(group.idleSeconds))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                
                HStack(spacing: 6) {
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
                    } else if group.effectiveSuggestion != .none && !group.isForeground && !group.isProtected {
                        Button(actionButtonTitle) {
                            coordinator.request(group.effectiveSuggestion, for: group)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.actionColor(group.effectiveSuggestion))
                        .controlSize(.mini)
                        .font(.system(size: 10, weight: .semibold))
                    } else {
                        Text(statusTitle)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.actionColor(statusAction))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.actionColor(statusAction).opacity(0.12), in: Capsule())
                    }

                    
                    Text(String(format: "%.0f", group.score.score))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.scoreColor(group.score.score))
                        .frame(width: 24, alignment: .trailing)
                }
            }

            
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().padding(.vertical, 2)

                    ScoreBreakdownView(
                        components: group.score.components,
                        estimatedMB: group.members.map(\.snapshot.memoryFootprintMB).max() ?? 0
                    )

                    if group.members.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("进程拓扑树")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)

                            ForEach(group.members) { member in
                                HStack(spacing: 6) {
                                    Text("↳")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                    Text(member.snapshot.processName)
                                        .font(.system(size: 10, weight: .medium))
                                    Text("PID \(member.snapshot.pid)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    Text(ByteFormat.mb(member.snapshot.memoryFootprintMB))
                                        .font(.system(size: 9, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()

                                    if let role = ProcessFamily.roleLabel(
                                        bundleID: member.snapshot.bundleID,
                                        processName: member.snapshot.processName
                                    ) {
                                        Text(role)
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.primary.opacity(0.04), in: Capsule())
                                    }
                                }
                                .padding(.leading, 6)
                            }
                        }
                    }

                    
                    HStack(spacing: 6) {
                        ForEach(alternateActions, id: \.rawValue) { action in
                            Button(action.title) {
                                coordinator.request(action, for: group)
                            }
                            .controlSize(.mini)
                            .disabled(group.isForeground || group.isProtected)
                        }

                        Spacer()

                        if canMarkFavorite {
                            Button(isFavorite ? "取消常用" : "设为常用") {
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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .modernCard(isHovered: isHovered, padding: 8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var actionButtonTitle: String {
        switch group.effectiveSuggestion {
        case .throttle: return "降优先级"
        case .quit: return "退出"
        case .freeze: return "冻结"
        case .none: return "应用"
        }
    }

    private var canMarkFavorite: Bool {
        guard !group.isKeepAlive else { return false }
        let bundleID = ProcessFamily.rootBundleID(from: group.primary.snapshot.bundleID)
            ?? group.primary.snapshot.bundleID
            ?? ""
        return !bundleID.isEmpty && !bundleID.hasPrefix("pid:")
    }

    private var alternateActions: [SuggestedAction] {
        SuggestedAction.userSelectable.filter { $0 != group.effectiveSuggestion }
    }

    private var statusAction: SuggestedAction {
        group.appliedAction ?? group.effectiveSuggestion
    }

    private var statusTitle: String {
        switch group.appliedAction {
        case .freeze: return "已冻结"
        case .throttle: return "已降级"
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
                        .font(.system(size: 10))
                        .frame(width: 54, alignment: .leading)
                    GeometryReader { geo in
                        let width = geo.size.width * min(1, abs(item.value) / 100)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.isPenalty ? Color.red.opacity(0.5) : Color.accentColor.opacity(0.55))
                            .frame(width: max(width, item.value == 0 ? 0 : 2), height: 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 4)
                    Text(String(format: "%+.1f", item.value))
                        .font(.system(size: 10, design: .rounded).monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(item.isPenalty ? .red : .secondary)
                }
            }
            Text("预计释放 \(ByteFormat.mb(estimatedMB)) · 退出后由系统自然回收")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
