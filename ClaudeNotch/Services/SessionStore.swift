import SwiftUI
import Observation

/// Single source of truth for observed sessions + usage. Views read this directly.
/// Mutated on the main actor from the hook server and transcript watchers.
@MainActor
@Observable
final class SessionStore {
    var sessions: [Session] = []
    var usage: UsageSnapshot = .empty

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
