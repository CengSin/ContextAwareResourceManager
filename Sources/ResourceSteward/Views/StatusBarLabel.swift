import ResourceStewardCore
import SwiftUI

struct StatusBarLabel: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        Image(systemName: "memorychip")
    }
}
