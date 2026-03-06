import Foundation
import UIKit
import UserNotifications

final class PigeonAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var coordinator: AppCoordinator?

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            coordinator?.didRegisterRemoteDeviceToken(deviceToken)
        }
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError _: Error
    ) {
        // Non-fatal: app continues with local notifications and BLE.
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            coordinator?.handleRemoteNotification(userInfo)
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            coordinator?.handleRemoteNotification(response.notification.request.content.userInfo)
        }
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run {
            coordinator?.handleRemoteNotification(notification.request.content.userInfo)
        }
        return []
    }
}
