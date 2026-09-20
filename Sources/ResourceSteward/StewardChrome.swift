import AppKit
import Combine
import ResourceStewardCore
import SwiftUI
import UserNotifications

@MainActor
final class StewardChrome {
    private let coordinator: AppCoordinator
    private let panel: ConfirmPanelController
    private let notifier: ReclaimNotifier
    private var cancellables = Set<AnyCancellable>()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.panel = ConfirmPanelController(coordinator: coordinator)
        self.notifier = ReclaimNotifier()
        notifier.prepare()
        if coordinator.settings.authorizationLevel == .sceneSwitch {
            notifier.requestAuthorization()
        }

        
        
        
        coordinator.$pendingBatch
            .combineLatest(coordinator.$pendingAction)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] batch, action in
                self?.panel.sync(hasPending: batch != nil || action != nil)
            }
            .store(in: &cancellables)

        coordinator.$settings
            .map(\.authorizationLevel)
            .removeDuplicates()
            .sink { [weak self] level in
                if level == .sceneSwitch {
                    self?.notifier.requestAuthorization()
                }
            }
            .store(in: &cancellables)

        coordinator.$lastAutoNotice
            .compactMap { $0 }
            .sink { [weak self] notice in
                self?.notifier.post(notice)
            }
            .store(in: &cancellables)
    }
}

@MainActor
final class ConfirmPanelController: NSObject, NSWindowDelegate {
    private let coordinator: AppCoordinator
    private var panel: NSPanel?
    private var hasPositioned = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func sync(hasPending: Bool) {
        if hasPending {
            show()
        } else {
            hide()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if coordinator.pendingBatch != nil {
            coordinator.cancelPendingBatch()
        } else if coordinator.pendingAction != nil {
            coordinator.cancelPending()
        }
        return false
    }

    private func show() {
        let panel = makePanelIfNeeded()
        let wasVisible = panel.isVisible
        present(panel)
        if !wasVisible {
            JevLog.info(
                "confirm_panel_show batch=\(coordinator.pendingBatch != nil) action=\(coordinator.pendingAction != nil)"
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.coordinator.pendingBatch != nil || self.coordinator.pendingAction != nil else { return }
            self.present(panel)
        }
    }

    private func present(_ panel: NSPanel) {
        fit(panel)
        if !hasPositioned {
            panel.center()
            hasPositioned = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard let panel, panel.isVisible else {
            hasPositioned = false
            return
        }
        panel.orderOut(nil)
        hasPositioned = false
        JevLog.info("confirm_panel_hide")
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "确认建议"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        
        
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let hosting = NSHostingView(rootView: ConfirmPromptView(coordinator: coordinator))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func fit(_ panel: NSPanel) {
        guard let view = panel.contentView else { return }
        view.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        var size = view.fittingSize
        if size.width < 10 || size.height < 10 {
            size = view.intrinsicContentSize
        }
        size.width = 380
        size.height = max(size.height, 140)
        panel.setContentSize(size)
    }
}

final class ReclaimNotifier: NSObject, UNUserNotificationCenterDelegate {
    func prepare() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ notice: AutoReclaimNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "cc.resourcesteward.auto-reclaim.\(notice.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
