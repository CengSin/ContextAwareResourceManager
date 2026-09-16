import ResourceStewardCore
import SwiftUI

struct WorkspaceEditorView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var draftName = ""
    @State private var selectedCore: Set<String> = []
    @State private var editingID: UUID?
    @State private var appQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工作场景由你手动定义。管家看最近 \(Int(coordinator.settings.matchingWindowMinutes)) 分钟你真正用过的 App：JetBrains IDE 这类只属于一个场景的软件才能定性，Chrome 这类共享软件只是弱线索。没用到的核心 App 不会把工作场景的分数压下去。证据不足则视为未分类，不套用场景保护，也不触发半自动处理。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)

            forecastSection

            if coordinator.workspaces.isEmpty {
                Text("还没有场景。从下面正在运行的 App 勾选核心应用，例如把 WebStorm / IntelliJ 和终端放进「办公」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                List {
                    ForEach(coordinator.workspaces) { workspace in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(workspace.name)
                                        .font(.subheadline.weight(.semibold))
                                    if coordinator.match.workspace?.id == workspace.id {
                                        Text("当前")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text("\(workspace.coreAppBundleIDs.count) 个核心 App")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let score = coordinator.match.scoresByWorkspaceID[workspace.id] {
                                    Text(String(format: "当前证据 %.1f", score))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("编辑") { beginEdit(workspace) }
                                .controlSize(.mini)
                            Button("删除", role: .destructive) {
                                coordinator.deleteWorkspace(workspace)
                                if editingID == workspace.id { resetDraft() }
                            }
                            .controlSize(.mini)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(height: 120)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(editingID == nil ? "新建场景" : "编辑场景")
                        .font(.caption.weight(.semibold))
                    TextField("名称，例如 办公 / 娱乐 / 会议", text: $draftName)
                        .textFieldStyle(.roundedBorder)

                    Text("核心 App（前台与后台正在运行的都可勾选）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("筛选名称或 bundle ID", text: $appQuery)
                        .textFieldStyle(.roundedBorder)

                    if filteredApps.isEmpty {
                        Text(coordinator.runningApps.isEmpty ? "没有检测到带 bundle ID 的用户 App。" : "没有匹配的运行中 App。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredApps) { app in
                            Toggle(isOn: coreBinding(app.bundleID)) {
                                HStack(spacing: 8) {
                                    AppIconView(path: app.path, size: 16)
                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: 6) {
                                            Text(app.name).font(.caption)
                                            if app.isBackground {
                                                Text("后台")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.primary.opacity(0.08), in: Capsule())
                                            }
                                        }
                                        Text(app.bundleID)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    HStack {
                        Button(editingID == nil ? "创建场景" : "保存修改", action: saveDraft)
                            .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || selectedCore.isEmpty)
                        if editingID != nil {
                            Button("取消", action: resetDraft)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("切换习惯")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if coordinator.forecastSampleCount == 0 {
                Text("使用一段时间并在场景之间切换后，这里会按当前时段显示你接下来最常去的场景。目前只用来展示习惯，不会据此改打分或自动处理。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("基于\(coordinator.forecastScope.title)的 \(coordinator.forecastSampleCount) 次切换")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(Array(coordinator.forecasts.prefix(3))) { forecast in
                    HStack {
                        Text(forecast.name)
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.0f%% · %d 次", forecast.probability * 100, forecast.sampleCount))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var filteredApps: [RunningAppInfo] {
        let query = appQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return coordinator.runningApps }
        return coordinator.runningApps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    private func coreBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { selectedCore.contains(bundleID) },
            set: { on in
                if on { selectedCore.insert(bundleID) } else { selectedCore.remove(bundleID) }
            }
        )
    }

    private func beginEdit(_ workspace: Workspace) {
        editingID = workspace.id
        draftName = workspace.name
        selectedCore = workspace.coreAppBundleIDs
    }

    private func resetDraft() {
        editingID = nil
        draftName = ""
        selectedCore = []
    }

    private func saveDraft() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !selectedCore.isEmpty else { return }
        if let id = editingID, let existing = coordinator.workspaces.first(where: { $0.id == id }) {
            var updated = existing
            updated.name = name
            updated.coreAppBundleIDs = selectedCore
            coordinator.saveWorkspace(updated)
        } else {
            coordinator.saveWorkspace(Workspace(name: name, coreAppBundleIDs: selectedCore))
        }
        resetDraft()
    }
}
