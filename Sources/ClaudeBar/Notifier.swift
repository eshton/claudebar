import AppKit
import UserNotifications
import ClaudeBarCore

/// macOS banners. Permission requests carry Approve / Deny buttons.
/// Inert when not running from a .app bundle (e.g. `swift run`), where UserNotifications would crash.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let permissionCategory = "clauderr.permission"
    private static let approve = "clauderr.approve", deny = "clauderr.deny"

    /// (permission request id, verdict) chosen from a banner button.
    var onDecision: ((String, PermissionVerdict) -> Void)?
    /// Any interaction with a banner (body click or a button).
    var onInteraction: (() -> Void)?
    /// Banner body clicked: session id to focus.
    var onOpen: ((String) -> Void)?

    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil

    func start() {
        guard let center else { return }
        center.delegate = self
        let approve = UNNotificationAction(identifier: Self.approve, title: "Approve", options: [])
        let deny = UNNotificationAction(identifier: Self.deny, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: [approve, deny],
                                   intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(id: String, title: String, body: String, sessionId: String, permissionId: String? = nil) {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = sessionId
        var info: [String: String] = ["session": sessionId]
        if let permissionId { info["permission"] = permissionId; c.categoryIdentifier = Self.permissionCategory }
        c.userInfo = info
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func withdraw(ids: [String]) {
        center?.removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])    // show even while ClaudeBar is frontmost
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        let session = info["session"] as? String
        let permission = info["permission"] as? String
        let action = r.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            self?.onInteraction?()
            switch action {
            case Self.approve: if let permission { self?.onDecision?(permission, .allow) }
            case Self.deny: if let permission { self?.onDecision?(permission, .deny) }
            case UNNotificationDefaultActionIdentifier: if let session { self?.onOpen?(session) }
            default: break
            }
            done()
        }
    }
}
