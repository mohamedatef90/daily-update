import Foundation
import UserNotifications

enum NotificationService {
    /// UNUserNotificationCenter requires a bundled app; a bare executable (swift run, .build/debug)
    /// crashes with "bundleProxyForCurrentProcess is nil".
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notifyUpdatesAvailable(count: Int) async {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Daily Update"
        content.body = count == 1 ? "1 update is available" : "\(count) updates are available"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "daily-update-available",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func notifyUpdateComplete(success: Int, failed: Int) async {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Daily Update"
        if failed == 0 {
            content.body = "Updated \(success) item\(success == 1 ? "" : "s") successfully"
        } else {
            content.body = "Updated \(success), failed \(failed)"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "daily-update-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
