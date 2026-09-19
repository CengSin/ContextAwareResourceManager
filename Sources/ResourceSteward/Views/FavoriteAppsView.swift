import ResourceStewardCore
import SwiftUI

struct FavoriteAppsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var appQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact Explanatory Pill
            HStack(spacing: 6) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.favoriteColor)
                Text("全场景常驻保活 · VPN 与 Docker 已默认免打扰")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.favoriteColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 4)

            // Current Favorites Section: Single-line Horizontal Chip Carousel
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("已保活应用")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("(\(coordinator.settings.favoriteApps.count))")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.favoriteColor)
                    Spacer()
                }
                .padding(.horizontal, 14)

                if coordinator.settings.favoriteApps.isEmpty {
                    Text("暂无自定义常用应用，从下方列表中勾选添加")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(coordinator.settings.favoriteApps) { app in
                                HStack(spacing: 5) {
                                    AppIconView(path: app.path, bundleID: app.bundleID, processName: app.name, size: 14)
                                    Text(app.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            coordinator.removeFavorite(bundleID: app.bundleID)
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .padding(2)
                                    }
                                    .buttonStyle(.plain)
                                    .help("移除保活")
                                }
                                .padding(.leading, 6)
                                .padding(.trailing, 4)
                                .padding(.vertical, 3)
                                .background(Theme.favoriteColor.opacity(0.12), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Theme.favoriteColor.opacity(0.24), lineWidth: 0.75)
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                    }
                }
            }

            Divider().padding(.horizontal, 14)

            // Inline Section Title & Search Box
            HStack(spacing: 8) {
                Text("从运行中选择")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()

                // Compact Search Box
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("快速筛选...", text: $appQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))

                    if !appQuery.isEmpty {
                        Button {
                            appQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 140)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 14)

            // Running Apps Selector ScrollView with Maximized Height
            ScrollView {
                LazyVStack(spacing: 4) {
                    if filteredApps.isEmpty {
                        Text(coordinator.runningApps.isEmpty ? "没有检测到带 Bundle ID 的第三方应用。" : "没有匹配的运行中应用。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(filteredApps) { app in
                            let builtin = KeepAlivePolicy.isKeepAlive(
                                bundleID: app.bundleID,
                                processName: app.name,
                                path: app.path
                            )
                            let isFav = coordinator.isFavorite(bundleID: app.bundleID)

                            HStack(spacing: 8) {
                                AppIconView(path: app.path, bundleID: app.bundleID, processName: app.name, size: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(app.name)
                                            .font(.system(size: 11, weight: .semibold))
                                            .lineLimit(1)

                                        if builtin {
                                            Text("系统常驻")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(Theme.favoriteColor)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Theme.favoriteColor.opacity(0.14), in: Capsule())
                                        }
                                        if app.isBackground {
                                            Text("后台")
                                                .font(.system(size: 8, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.primary.opacity(0.06), in: Capsule())
                                        }
                                    }

                                    Text(app.bundleID)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                if builtin {
                                    Text("默认常驻")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Toggle("", isOn: favoriteBinding(app))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isFav ? Theme.favoriteColor.opacity(0.08) : Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isFav ? Theme.favoriteColor.opacity(0.22) : Color.white.opacity(0.05), lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !builtin else { return }
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    favoriteBinding(app).wrappedValue.toggle()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
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
