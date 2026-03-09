import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestPermissionIfNeeded() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestPermission()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func showMessageNotification(from senderName: String, preview: String, conversationID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body = String(preview.prefix(100))
        content.sound = .default
        content.userInfo = ["conversationID": conversationID.uuidString]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
