import Foundation

/// An interactive question surfaced from an AskUserQuestion tool call.
struct Question: Identifiable, Equatable {
    let id: String                 // correlates hook <-> answer
    var header: String?            // short tag, e.g. "Theme"
    var prompt: String             // "Which theme should the new dashboard default to?"
    var choices: [Choice]
    var createdAt: Date = Date()

    struct Choice: Identifiable, Equatable {
        let id = UUID()
        var index: Int             // 1-based, drives the ⌥1 / ⌥2 shortcuts
        var label: String          // "Dark"
        var detail: String?        // "Matches the terminal aesthetic"
    }
}
