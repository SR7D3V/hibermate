import Foundation
import HibermateCore
import UserNotifications

/// Local notifications only. Nothing leaves the Mac.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ reason: ReleaseReason, slept: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Hibermate"
        content.body = reason.notificationBody(slept: slept)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
