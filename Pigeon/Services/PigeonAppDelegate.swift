import Foundation
import UIKit

final class PigeonAppDelegate: NSObject, UIApplicationDelegate {
    weak var coordinator: AppCoordinator?

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
}
