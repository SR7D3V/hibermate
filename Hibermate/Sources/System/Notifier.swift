import Foundation
import HibermateCore
import UserNotifications

/// Local notifications only. Nothing leaves the Mac.
enum Notifier {
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error as NSError? {
                appLog.error("Notification permission request failed: \(error.domain, privacy: .public) \(error.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
            } else {
                appLog.notice("Notification permission granted: \(granted, privacy: .public)")
            }
            logStatus()
        }
    }

    static func logStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            appLog.notice("Notification settings: authorization \(s.authorizationStatus.rawValue, privacy: .public), alerts \(s.alertSetting.rawValue, privacy: .public)")
        }
    }

    static func post(_ reason: ReleaseReason, slept: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Hibermate"
        content.body = reason.notificationBody(slept: slept)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error as NSError? {
                appLog.error("Posting notification failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            }
        }
    }
}
