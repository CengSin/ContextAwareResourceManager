import AppKit
import ResourceStewardCore
import SwiftUI

@main
struct ResourceStewardApp: App {
    @StateObject private var coordinator: AppCoordinator

    init() {
        let loaded: AppCoordinator
        do {
            loaded = try AppCoordinator()
        } catch {
            fputs("ResourceSteward failed to open local store: \(error)\n", stderr)
            loaded = try! AppCoordinator(store: LocalStore(path: NSTemporaryDirectory() + "resource-steward.sqlite"))
        }
        _coordinator = StateObject(wrappedValue: loaded)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(coordinator)
                .onAppear { coordinator.start() }
        } label: {
            StatusBarLabel()
                .environmentObject(coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}
