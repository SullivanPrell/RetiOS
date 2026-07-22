import Foundation
import Observation
import UserNotifications

// MARK: - App-level tab enum

/// Used by both RootView (tab / sidebar selection) and NotificationManager
/// (navigation intent published on notification tap).
enum AppTab: String, Hashable, CaseIterable {
    case messages   = "messages"
    case calls      = "calls"
    case nomadNet   = "nomadNet"
    case map        = "map"
    case interfaces = "interfaces"
    case tools      = "tools"
    case settings   = "settings"
}

// MARK: - NotificationManager

/// Owns UNUserNotificationCenter interaction for the whole app.
///
/// Responsibilities:
///   • Request permission once at launch.
///   • Register notification categories (MESSAGE, CALL with Accept/Decline actions).
///   • Schedule / cancel local notifications for inbound messages and calls.
///   • Act as UNUserNotificationCenterDelegate and translate taps into
///     `navigateTo` / `openConversationHash` for the view hierarchy to observe.
///
/// Designed as a singleton so StackController and CallsController can reach it
/// without needing the SwiftUI environment.  Use `NotificationManager.shared`
/// everywhere; inject it as `@EnvironmentObject` in views that need to observe it.
@MainActor
@Observable
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    // MARK: - Published navigation intents

    /// Set by the notification delegate; consumed by RootView to switch tabs.
    var navigateTo: AppTab? = nil
    /// Set by the notification delegate; consumed by ConversationsView to push
    /// directly to the relevant conversation thread.
    var openConversationHash: String? = nil

    // MARK: - Menu-command intents (macOS / hardware keyboard)
    //
    // Bumped by the app's menu-bar commands (see RetiOSApp `.commands`). Views
    // observe the relevant counter via `.onChange` and act. Routed through this
    // singleton (rather than passing @StateObject controllers into the `Commands`
    // builder) because SwiftUI does not flow the environment into `.commands`.

    /// Open the New Message composer.
    var requestCompose = 0
    /// Open the Add Contact (by destination hash) sheet.
    var requestAddContact = 0
    /// Open the New Call sheet.
    var requestNewCall = 0
    /// Send an LXMF announce now.
    var requestAnnounce = 0
    /// Sync from the propagation node now.
    var requestSync = 0

    // MARK: - Injected dependencies

    /// Needed to Accept / Decline calls from notification action buttons.
    /// Set by RetiOSApp after CallsController is created.
    weak var callsController: CallsController?

    // MARK: - Init

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    // MARK: - Permission

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationSettings()
        guard existing.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Categories

    private func registerCategories() {
        // CALL — Accept brings the app to foreground; Decline runs silently in background.
        let accept = UNNotificationAction(
            identifier: NotifAction.acceptCall,
            title: "Accept",
            options: [.foreground]
        )
        let decline = UNNotificationAction(
            identifier: NotifAction.declineCall,
            title: "Decline",
            options: [.destructive]
        )
        let callCategory = UNNotificationCategory(
            identifier: NotifCategory.call,
            actions: [accept, decline],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // MESSAGE — no custom actions; tap opens the conversation.
        let messageCategory = UNNotificationCategory(
            identifier: NotifCategory.message,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([callCategory, messageCategory])
    }

    // MARK: - Schedule: message

    /// Call this for every inbound LXMF message (outbound messages are never notified).
    func scheduleMessageNotification(senderName: String, preview: String, peerHash: String) {
        let content = UNMutableNotificationContent()
        content.title = senderName
        content.body  = preview.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "New message"
        content.sound = .default
        content.categoryIdentifier = NotifCategory.message
        content.userInfo = [UserInfoKey.peerHash: peerHash]

        let request = UNNotificationRequest(
            identifier: "msg-\(UUID().uuidString)",
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Schedule / cancel: call

    func scheduleCallNotification(callerHash: String, callerName: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "Incoming Call"
        content.body  = callerName.map { "From \($0)" }
                        ?? "From \(callerHash.prefix(8))…"
        #if os(iOS)
        content.sound = .defaultRingtone
        #else
        content.sound = .default
        #endif
        content.categoryIdentifier = NotifCategory.call
        content.userInfo = [UserInfoKey.callerHash: callerHash]
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: callNotifId(callerHash),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func cancelCallNotification(callerHash: String) {
        let id = callNotifId(callerHash)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: - Private helpers

    private func callNotifId(_ hash: String) -> String { "call-\(hash)" }

    // MARK: - Constants

    private enum NotifCategory {
        static let call    = "CALL"
        static let message = "MESSAGE"
    }

    private enum NotifAction {
        static let acceptCall  = "ACCEPT_CALL"
        static let declineCall = "DECLINE_CALL"
    }

    private enum UserInfoKey {
        static let peerHash   = "peerHash"
        static let callerHash = "callerHash"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Called while the app is in the foreground.
    /// Message banners are shown as usual; call banners are suppressed because the
    /// in-app incoming-call UI is already visible.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == NotifCategory.call {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    /// Called when the user taps a notification or an action button.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content    = response.notification.request.content
        let actionId   = response.actionIdentifier
        let peerHash   = content.userInfo[NotificationManager.UserInfoKey.peerHash]   as? String
        let callerHash = content.userInfo[NotificationManager.UserInfoKey.callerHash] as? String

        Task { @MainActor in
            switch (content.categoryIdentifier, actionId) {

            case (NotifCategory.call, NotifAction.acceptCall):
                // Action has .foreground — app comes to foreground automatically.
                // Answer immediately (the button says "Accept" — making the user
                // tap Accept a second time in-app was a trap), then show the
                // active-call UI on the Calls tab.
                self.callsController?.acceptIncomingCall()
                self.navigateTo = .calls

            case (NotifCategory.call, NotifAction.declineCall):
                // Runs as a background action — reject without bringing app forward.
                self.callsController?.rejectIncomingCall()

            case (NotifCategory.message, _):
                // Tap on message notification → open that conversation.
                self.navigateTo = .messages
                if let hash = peerHash {
                    self.openConversationHash = hash
                }

            default:
                // Plain tap on call notification (no action button).
                self.navigateTo = .calls
            }

            completionHandler()
        }
    }
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
