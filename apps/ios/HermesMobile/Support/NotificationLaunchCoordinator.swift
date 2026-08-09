import UIKit
import UserNotifications

/// Process-lifetime owner for notification registration and response delivery.
/// UIKit creates this through `AppDelegate`, before any SwiftUI view task runs.
@MainActor
final class NotificationLaunchCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private struct PresentationBox: @unchecked Sendable {
        let userInfo: [AnyHashable: Any]
        let completion: (UNNotificationPresentationOptions) -> Void
    }

    enum Event: Sendable {
        case tap(NotificationService.Tap)
    }

    private var pending: [Event] = []
    private var didInstall = false
    private var tapHandler: (@MainActor @Sendable (NotificationService.Tap) -> Void)?
    private var reconciliationHandler: (@MainActor @Sendable () -> Void)?
    private var owesReconciliation = false

    func install(center: UNUserNotificationCenter = .current()) {
        guard !didInstall else { return }
        didInstall = true
        center.delegate = self
        NotificationService.registerCategories(center: center)
    }

    func attachTapHandler(
        _ handler: @escaping @MainActor @Sendable (NotificationService.Tap) -> Void
    ) {
        tapHandler = handler
        NotificationService.setTapHandler(handler)
        drainIfReady()
    }

    func attachReconciliationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        reconciliationHandler = handler
        if owesReconciliation {
            owesReconciliation = false
            handler()
        }
    }

    func receive(_ event: Event) {
        guard isReady(for: event) else {
            pending.append(event)
            return
        }
        route(event)
    }

    private func isReady(for event: Event) -> Bool {
        tapHandler != nil
    }

    private func drainIfReady() {
        guard !pending.isEmpty else { return }
        var blocked: [Event] = []
        for event in pending {
            isReady(for: event) ? route(event) : blocked.append(event)
        }
        pending = blocked
    }

    private func route(_ event: Event) {
        switch event {
        case .tap(let tap):
            tapHandler?(tap)
        }
    }

    private func notifyReconciliation() {
        if let reconciliationHandler {
            reconciliationHandler()
        } else {
            owesReconciliation = true
        }
    }

    func receiveForegroundPush(_ tap: NotificationService.Tap?) {
        guard tap != nil else { return }
        notifyReconciliation()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let box = PresentationBox(
            userInfo: notification.request.content.userInfo,
            completion: completionHandler
        )
        Task { @MainActor in
            self.receiveForegroundPush(
                NotificationService.decodeTap(from: box.userInfo)
            )
            box.completion(
                NotificationService.foregroundPresentationOptions(userInfo: box.userInfo)
            )
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let event: Event?
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let tap = NotificationService.decodeTap(from: userInfo) {
            event = .tap(tap)
        } else {
            event = nil
        }
        guard let event else {
            completionHandler()
            return
        }
        completionHandler()
        Task { @MainActor in self.receive(event) }
    }
}
