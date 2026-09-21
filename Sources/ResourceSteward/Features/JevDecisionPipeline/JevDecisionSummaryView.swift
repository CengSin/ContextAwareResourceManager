import ResourceStewardCore
import SwiftUI

struct JevDecisionSummaryView: View {
    let item: PendingDecisionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.group.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("建议\(item.action.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.actionColor(item.action))
            }
            Text(item.evidence.loadSummary)
                .accessibilityIdentifier("jev.loadAssessment")
            Text("已观测：\(Int(item.evidence.idleSeconds / 60)) 分钟未到前台 · 占用 \(Int(item.evidence.memoryMB)) MB")
                .accessibilityIdentifier("jev.observedEvidence")
            Text("Jev 判断：\(item.evidence.judgmentSummary)")
                .accessibilityIdentifier("jev.semanticAssessment")
            Text("动作置信度 \(Int(item.evidence.confidence * 100))%（不代表退出安全概率）")
                .accessibilityIdentifier("jev.actionConfidence")
            if item.action == .quit {
                Text("未保存内容和后台任务状态未知，请确认当前工作可以中断。")
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("jev.decisionSummary")
    }
}
