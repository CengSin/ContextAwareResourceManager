import AppKit
import ResourceStewardCore
import SwiftUI

@MainActor
final class StewardAppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?
    private var chrome: StewardChrome?

    func bindIfNeeded(_ coordinator: AppCoordinator) {
        guard chrome == nil else { return }
        self.coordinator = coordinator
        chrome = StewardChrome(coordinator: coordinator)
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}

@main
struct ResourceStewardApp: App {
    @NSApplicationDelegateAdaptor(StewardAppDelegate.self) private var appDelegate
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
        } label: {
            StatusBarLabel()
                .environmentObject(coordinator)
                .onAppear {
                    appDelegate.bindIfNeeded(coordinator)
                }
        }
        .menuBarExtraStyle(.window)
    }
}
