import Foundation

/// Lines added and removed by one file-editing tool call, read from its input. Not a
/// real diff — lines present on both sides of an edit simply cancel out — but it is what
/// a "+12 −3" badge needs, and it needs nothing but the hook payload.
struct LineDelta: Equatable {
    var added = 0
    var removed = 0

    static func from(tool: String, input: [String: Any]) -> LineDelta {
        switch tool {
        case "Edit":
            return edit(old: input["old_string"] as? String, new: input["new_string"] as? String)
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return edits.reduce(LineDelta()) { sum, e in
                let d = edit(old: e["old_string"] as? String, new: e["new_string"] as? String)
                return LineDelta(added: sum.added + d.added, removed: sum.removed + d.removed)
            }
        case "Write":
            return LineDelta(added: lines(input["content"] as? String).count)
        case "NotebookEdit":
            return LineDelta(added: lines(input["new_source"] as? String).count)
        default:
            return LineDelta()
        }
    }

    /// Lines only on the old side are removed, lines only on the new side added; a line
    /// on both sides (as a multiset) is unchanged context.
    static func edit(old: String?, new: String?) -> LineDelta {
        var pool: [String: Int] = [:]
        for line in lines(old) { pool[line, default: 0] += 1 }
        var added = 0
        for line in lines(new) {
            if let n = pool[line], n > 0 { pool[line] = n - 1 } else { added += 1 }
        }
        return LineDelta(added: added, removed: pool.values.reduce(0, +))
    }

    private static func lines(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }       // trailing newline is not a line
        return parts
    }
}
