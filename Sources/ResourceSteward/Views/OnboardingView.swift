import ResourceStewardCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.pressureColor(.normal))
                VStack(alignment: .leading, spacing: 2) {
                    Text("场景资源管家")
                        .font(.title3.weight(.semibold))
                    Text("先看清它能做什么、不能做什么")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                OnboardPoint(
                    icon: "rectangle.3.group",
                    title: "理解当前工作场景",
                    detail: "根据你定义的核心 App，判断现在哪些进程不那么重要。"
                )
                OnboardPoint(
                    icon: "hand.raised",
                    title: "不会直接压缩或回收内存",
                    detail: "macOS 没有公开 API 能压缩其他进程的内存。本工具只做降优先级、冻结或请求退出。"
                )
                OnboardPoint(
                    icon: "pause.rectangle",
                    title: "默认只建议，切场景半自动可在设置里打开",
                    detail: "默认所有处理都要你确认。开启 Level 1 后，切换到已识别场景时会自动冻结离场景应用；退出建议会改成冻结。未分类不触发。"
                )
                OnboardPoint(
                    icon: "questionmark.circle",
                    title: "「预计可释放」是估算",
                    detail: "数字来自进程当前占用，不是本工具已经回收的结果，也不构成效果承诺。"
                )
            }

            Button(action: coordinator.completeOnboarding) {
                Text("我明白了")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: Theme.panelWidth, height: Theme.panelHeight)
    }
}

private struct OnboardPoint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
