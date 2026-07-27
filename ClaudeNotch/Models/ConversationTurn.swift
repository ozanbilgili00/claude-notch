import Foundation

/// One rendered turn in a session's conversation view.
///
/// Built incrementally by `TranscriptWatcher` as new transcript lines arrive, so the
/// focused view never touches the filesystem itself.
struct ConversationTurn: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }

    let id: Int          // position in the session's turn list; stable for SwiftUI
    var role: Role
    var text: String
}
