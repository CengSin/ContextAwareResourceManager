import ResourceStewardCore
import SwiftUI

struct ConfirmPromptView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Group {
            if let batch = coordinator.pendingBatch {
                batchBody(batch)
            } else if let pending = coordinator.pendingAction {
                actionBody(pending)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
    }

    private func batchBody(_ batch: PendingDecisionBatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jev 建议按当前负载处理这些应用")
                .font(.headline)
            Text("降低优先级不会回收内存；退出才会让系统回收占用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(batch.items) { item in
                    HStack {
                        Text(item.group.displayName)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(item.action.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.actionColor(item.action))
                    }
                }
            }
            HStack {
                Button("暂不处理") {
                    coordinator.cancelPendingBatch()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认执行") {
                    coordinator.confirmPendingBatch()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(batch.items.contains(where: { $0.action == .quit }) ? .red : .accentColor)
            }
        }
    }

    private func actionBody(_ pending: PendingAction) -> some View {
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
                Button("取消") {
                    coordinator.cancelPending()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认执行") {
                    coordinator.confirmPending()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(pending.action == .quit ? .red : .accentColor)
            }
        }
    }
}
