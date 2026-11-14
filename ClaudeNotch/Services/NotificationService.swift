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
        case usageWarning       // a usage window crossed 80 % / 95 %
        case usageReset         // a window that had been tight started over

        /// A built-in macOS alert sound; distinct per kind so they're tellable apart.
        var soundName: String {
            switch self {
            case .needsAttention: return "Funk"
            case .completed:      return "Glass"
            case .failed:         return "Basso"
            case .usageWarning:   return "Submarine"
            case .usageReset:     return "Hero"
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

    /// Usage alerts belong to no session, so they are titled by the window instead.
    static func notifyUsage(_ alert: UsageAlerts.Alert) {
        let window: String
        switch alert.window {
        case .fiveHour: window = L(.usageFiveHourLong)
        case .weekly:   window = L(.usageWeeklyLong)
        case .opus:     window = L(.usageOpusLong)
        }
        switch alert.kind {
        case .threshold(let pct):
            post(.usageWarning,
                 title: L(.usageAlertTitle, window, L10n.percent(pct, Localization.shared.language)),
                 body: L(.usageAlertBody, UsageSnapshot.countdown(until: alert.resetsAt)))
        case .reset:
            post(.usageReset, title: L(.usageResetTitle, window), body: L(.usageResetBody))
        }
    }

    private static func post(_ kind: Kind, title: String, body: String) {
        guard !UserDefaults.standard.muteSounds else { return }
        NSSound(named: kind.soundName)?.play()
        guard UserDefaults.standard.notificationsEnabled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
