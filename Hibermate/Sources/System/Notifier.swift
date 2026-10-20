import AppKit
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

    /// Whether macOS currently lets Hibermate show notifications. Unsigned
    /// builds are never prompted; the user has to turn it on in System Settings.
    static func isAllowed(_ completion: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let allowed = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(allowed) } }
        }
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(HelperIdentity.appBundleID)")!
        NSWorkspace.shared.open(url)
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
