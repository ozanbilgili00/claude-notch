import SwiftUI
import Observation

/// Single source of truth for observed sessions + usage. Views read this directly.
/// Mutated on the main actor from the hook server and transcript watchers.
@MainActor
@Observable
final class SessionStore {
    var sessions: [Session] = []
    var usage: UsageSnapshot = .empty

    /// The latest moment worth reacting to — a turn finishing, something needing the
    /// user, a usage warning. Views animate on `event.id` changing; nothing reads it as
    /// state, so it never needs clearing.
    var event: NotchEvent?

    func signal(_ kind: NotchEvent.Kind, session: String? = nil) {
        event = NotchEvent(kind: kind, sessionID: session)
    }

    /// The current event if it belongs to this session — for a row's own creature.
    func event(for sessionID: String) -> NotchEvent? {
        event?.sessionID == sessionID ? event : nil
    }

    /// Selected session in the expanded UI (defaults to the most urgent).
    var selectedID: String?

    /// Wired by the coordinator: the UI calls these when the user answers.
    @ObservationIgnored var onPermissionDecision: ((String, PermissionDecision) -> Void)?
    @ObservationIgnored var onQuestionAnswer: ((String, Int) -> Void)?

    // MARK: Derived

    /// The session that should drive the *closed* notch: most urgent, then most recent.
    var focusedSession: Session? {
        sessions.max { a, b in
            if a.status.priority != b.status.priority {
                return a.status.priority < b.status.priority
            }
            return a.lastActivityAt < b.lastActivityAt
        }
    }

    /// Any session currently blocking on the user (permission or question).
    var blockingSession: Session? {
        sessions.first { $0.pendingPermission != nil || $0.pendingQuestion != nil }
    }

    var aggregateStatus: SessionStatus {
        focusedSession?.status ?? .idle
    }

    var workingCount: Int { sessions.filter { $0.status == .working }.count }

    /// The most recent turn result still worth announcing. Successful ones clear themselves
    /// a few seconds after the turn ends (see `HookCoordinator`), failures stay until they
    /// are dismissed — so the presence of one is exactly "something just finished".
    var recentCompletion: Completion? {
        sessions
            .filter { $0.completion != nil }
            .max { $0.lastActivityAt < $1.lastActivityAt }?
            .completion
    }

    /// One-word summary of everything, shared by the closed pill and the panel header so
    /// the two never disagree mid-morph.
    /// Kept short in every language: it flies between the two layouts as one element, so
    /// the narrow closed pill sets the budget for both.
    var statusWord: String {
        if let b = blockingSession {
            return b.pendingPermission != nil ? L(.statusPermission) : L(.statusQuestion)
        }
        switch aggregateStatus {
        case .working: return L(.statusWorking)
        case .waiting: return L(.statusWaiting)
        case .error:   return L(.statusError)
        case .idle:    return L(.statusIdle)
        }
    }

    // MARK: Mutation helpers

    func upsert(_ session: Session) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
    }

    func update(_ id: String, _ mutate: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[i])
    }

    func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func session(_ id: String) -> Session? {
        sessions.first { $0.id == id }
    }
}

/// A one-off happening for the closed notch and the edge dock to acknowledge.
struct NotchEvent: Equatable, Identifiable {
    enum Kind: Equatable { case completed, attention, failed, usageWarning, usageReset }
    let id = UUID()
    var kind: Kind
    /// The session it happened in, when it happened in one.
    var sessionID: String? = nil
}
