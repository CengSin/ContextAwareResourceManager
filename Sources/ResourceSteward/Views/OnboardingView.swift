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
                    Text("资源管家")
                        .font(.title3.weight(.semibold))
                    Text("先看清它能做什么、不能做什么")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                OnboardPoint(
                    icon: "rectangle.3.group",
                    title: "看负载和正在运行的灰区 App",
                    detail: "前台、VPN/会议/IM、常用和系统进程不会进名单。其余正在运行的第三方 App 连同当前 CPU/内存压力一起交给 Jev。"
                )
                OnboardPoint(
                    icon: "hand.raised",
                    title: "不会直接压缩或回收内存",
                    detail: "macOS 没有公开 API 能压缩其他进程的内存。本工具只做降低优先级或请求退出，没有冻结。"
                )
                OnboardPoint(
                    icon: "pause.rectangle",
                    title: "默认只建议，半自动可在设置里打开",
                    detail: "Level 0：Jev 给出保留/降级/退出后弹出独立窗口让你确认。Level 1：同一套决策自动执行，完成后发系统通知。系统进程、VPN/容器和「常用」里的应用不会动。"
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
