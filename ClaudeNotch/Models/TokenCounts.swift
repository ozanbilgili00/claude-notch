import Foundation

/// Token usage split the way it matters to a reader. `main` (fresh input + output) is the
/// number worth showing; cache reads dwarf it — one long session reads hundreds of
/// millions of cached tokens — so summing everything, as the notch once did, produced a
/// figure too large to mean anything.
struct TokenCounts: Equatable, Codable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var main: Int { input + output }
    var cache: Int { cacheRead + cacheWrite }
    var isEmpty: Bool { main == 0 && cache == 0 }

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// From an API `usage` object. Missing keys count as zero.
    init(usage: [String: Any]) {
        func int(_ key: String) -> Int { (usage[key] as? Int) ?? 0 }
        self.init(input: int("input_tokens"), output: int("output_tokens"),
                  cacheRead: int("cache_read_input_tokens"),
                  cacheWrite: int("cache_creation_input_tokens"))
    }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
    static func - (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input - b.input, output: a.output - b.output,
                    cacheRead: a.cacheRead - b.cacheRead, cacheWrite: a.cacheWrite - b.cacheWrite)
    }
    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// Running total that counts each API message once. Claude Code writes one transcript
/// line per content block of a reply, and every one of those lines repeats the reply's
/// `message.id` and `usage` — summing lines counted most replies two or three times.
/// A later line for the same id replaces the earlier figure rather than adding to it.
struct TokenTally {
    private(set) var total = TokenCounts()
    private var byID: [String: TokenCounts] = [:]

    mutating func record(id: String?, _ counts: TokenCounts) {
        guard let id else { total += counts; return }
        if let previous = byID[id] { total = total - previous }
        byID[id] = counts
        total += counts
    }
}

/// "950", "12.4k", "3.4M" — short enough for a badge.
enum CompactNumber {
    static func format(_ n: Int, decimalComma: Bool = false) -> String {
        let value = Double(n)
        let text: String
        switch abs(value) {
        case 1_000_000_000...: text = trimmed(value / 1_000_000_000) + "B"
        case 1_000_000...:     text = trimmed(value / 1_000_000) + "M"
        case 1_000...:         text = trimmed(value / 1_000) + "k"
        default:               text = String(n)
        }
        return decimalComma ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// One decimal under 100 ("12.4"), none above ("124"); a trailing ".0" is dropped.
    private static func trimmed(_ v: Double) -> String {
        if v >= 100 { return String(Int(v.rounded())) }
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
