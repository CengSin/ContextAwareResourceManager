import ResourceStewardCore
import SwiftUI

struct StatusBarLabel: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.pressureColor(coordinator.pressure), Color.primary)
            Circle()
                .fill(Theme.pressureColor(coordinator.pressure))
                .frame(width: 6, height: 6)
        }
        .help(tooltip)
    }

    private var tooltip: String {
        let ram = ByteFormat.string(coordinator.hostMemory.usedBytes)
        let total = ByteFormat.string(coordinator.hostMemory.physicalBytes)
        let gpu = coordinator.hostGPU.available
            ? String(format: "GPU %.0f%%", coordinator.hostGPU.usagePercent)
            : "GPU 不可用"
        return String(
            format: "场景管家 · %@ · CPU %.0f%% · %@ · RAM %@ / %@ · 内存压力 %@",
            coordinator.match.displayName,
            coordinator.hostCPU.usagePercent,
            gpu,
            ram,
            total,
            coordinator.pressure.title
        )
    }
}
