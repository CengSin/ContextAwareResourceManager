import ResourceStewardCore
import SwiftUI

struct FavoriteAppsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var appQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("常用应用在任何场景都不会被降低优先级、冻结或退出。适合数据库客户端、开发环境、你一直要开着的软件。VPN / OrbStack / Docker 等已默认常驻，不必再加。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)

            if coordinator.settings.favoriteApps.isEmpty {
                Text("还没有常用应用。从下面正在运行的 App 勾选即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已选 \(coordinator.settings.favoriteApps.count) 个")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(coordinator.settings.favoriteApps) { app in
                        HStack(spacing: 8) {
                            AppIconView(path: app.path, size: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(app.name)
                                    .font(.caption)
                                Text(app.bundleID)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("移除") {
                                coordinator.removeFavorite(bundleID: app.bundleID)
                            }
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("从正在运行的 App 添加")
                        .font(.caption.weight(.semibold))
                    TextField("筛选名称或 bundle ID", text: $appQuery)
                        .textFieldStyle(.roundedBorder)

                    if filteredApps.isEmpty {
                        Text(coordinator.runningApps.isEmpty ? "没有检测到带 bundle ID 的用户 App。" : "没有匹配的运行中 App。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredApps) { app in
                            let builtin = KeepAlivePolicy.isKeepAlive(
                                bundleID: app.bundleID,
                                processName: app.name,
                                path: app.path
                            )
                            Toggle(isOn: favoriteBinding(app)) {
                                HStack(spacing: 8) {
                                    AppIconView(path: app.path, size: 16)
                                    VStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: 6) {
                                            Text(app.name).font(.caption)
                                            if builtin {
                                                Text("系统常驻")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.purple.opacity(0.16), in: Capsule())
                                            }
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
                            .disabled(builtin)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private var filteredApps: [RunningAppInfo] {
        let query = appQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let apps = coordinator.runningApps.filter { app in
            !ProcessFamily.isCompanion(bundleID: app.bundleID, processName: app.name)
        }
        if query.isEmpty { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    private func favoriteBinding(_ app: RunningAppInfo) -> Binding<Bool> {
        Binding(
            get: { coordinator.isFavorite(bundleID: app.bundleID) },
            set: { on in
                if on {
                    coordinator.addFavorite(bundleID: app.bundleID, name: app.name, path: app.path)
                } else {
                    coordinator.removeFavorite(bundleID: app.bundleID)
                }
            }
        )
    }
}
