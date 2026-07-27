import AppKit
import UserNotifications

/// Alerts for events the user should notice while looking somewhere else: a session
/// needing permission or an answer, and a task finishing.
///
/// The speaker button in the notch header writes `muteSounds`; when it is on, this
/// service stays completely quiet (no sound, no banner). System notifications are
/// additionally gated by the `notifications` preference, and degrade to sound-only when
/// the user has denied notification access.
@MainActor
enum NotificationService {

    enum Kind {
        case needsAttention     // permission request or question waiting
        case completed          // task finished successfully
        case failed             // task finished with an error

        /// A built-in macOS alert sound; distinct per kind so they're tellable apart.
        var soundName: String {
            switch self {
            case .needsAttention: return "Funk"
            case .completed:      return "Glass"
            case .failed:         return "Basso"
            }
        }
    }

    private static var authorized = false

    /// Ask once at launch. Denial is fine — we fall back to sound only.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in authorized = granted }
            }
    }

    static func notify(_ kind: Kind, session: Session, body: String) {
        guard !UserDefaults.standard.muteSounds else { return }

        NSSound(named: kind.soundName)?.play()

        guard UserDefaults.standard.notificationsEnabled, authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = session.displayName
        content.body = body
        content.userInfo["sessionID"] = session.id   // tapping focuses this session
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
