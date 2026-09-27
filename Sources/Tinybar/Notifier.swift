import Foundation
import TinybarCore
import UserNotifications

/// Delivers Limit Alerts as macOS notifications.
@MainActor
final class Notifier {
    /// UNUserNotificationCenter requires a real app bundle; unbundled dev builds skip notifications.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestAuthorizationOnce() {
        guard let center, !UserDefaults.standard.bool(forKey: "didRequestNotifications") else { return }
        UserDefaults.standard.set(true, forKey: "didRequestNotifications")
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(_ alert: LimitAlertPlanner.Alert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        switch alert {
        case let .threshold(provider, window, percent, resetsAt):
            content.title = "\(provider.displayName) \(window): \(100 - percent)% left"
            if let resetsAt {
                content.body = "Resets in \(Format.countdown(to: resetsAt))."
            }
        case let .reset(provider, window):
            content.title = "\(provider.displayName) \(window) limit reset"
            content.body = "You're back to full capacity."
        }
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
