import Foundation
import UserNotifications

final class CompletionNotice: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotice()
    func enable() async throws -> Bool {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    func send() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = "KongVox · 全文配音已完成"
        content.body = "可以试听或导出完整音频与字幕了。"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}
