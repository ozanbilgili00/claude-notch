import Foundation

/// Discovers Claude Code sessions that are running but haven't fired a hook yet (e.g.
/// idle sessions, or sessions that were already open when the notch launched). Works by
/// finding running `claude` CLI processes, resolving each one's working directory, and
/// matching it to the most-recent transcript(s) in that project's folder.
enum SessionDiscovery {
    struct Found: Sendable {
        let id: String
        let cwd: String
        let pid: Int32
        let tty: String?
        let terminalApp: String?
    }

    static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    /// - Parameter known: session IDs the hooks already told us about. Their transcripts
    ///   are pinned to those sessions, so they're excluded from the guesswork below —
    ///   that keeps hook-known sessions stable when several share one directory.
    static func scan(known: Set<String> = []) -> [Found] {
        let procs = claudeProcesses()
        guard !procs.isEmpty else { return [] }

        // Group running processes by working directory.
        var byCwd: [String: [ClaudeProcess]] = [:]
        for p in procs {
            if let cwd = workingDirectory(of: p.pid) { byCwd[cwd, default: []].append(p) }
        }

        var found: [Found] = []
        for (cwd, list) in byCwd {
            let ids = recentSessionIDs(cwd: cwd, limit: list.count, excluding: known)
            // One session per running process; pairing is exact when a directory has a
            // single session (the common case), approximate when several share a folder.
            for (i, id) in ids.enumerated() {
                let proc = list[min(i, list.count - 1)]
                found.append(Found(id: id, cwd: cwd, pid: proc.pid,
                                   tty: proc.tty, terminalApp: proc.terminalApp))
            }
        }
        return found
    }

    // MARK: Process inspection

    private struct ClaudeProcess {
        let pid: Int32
        let tty: String?
        let terminalApp: String?
    }

    private static func claudeProcesses() -> [ClaudeProcess] {
        // `pgrep -x claude` matches the CLI process exactly (not the desktop app or us).
        let out = shell("/usr/bin/pgrep", ["-x", "claude"])
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            guard let pid = Int32(line) else { return nil }
            return ClaudeProcess(pid: pid, tty: tty(of: pid), terminalApp: terminalApp(of: pid))
        }
    }

    /// Terminals we can name. The key is the process name as `ps -o comm=` reports it
    /// (lowercased, last path component); the value is what we show and what
    /// `TerminalBridge` switches on.
    private static let knownTerminals: [String: String] = [
        "terminal": "Terminal",
        "iterm2": "iTerm2",
        "iterm": "iTerm2",
        "ghostty": "Ghostty",
        "wezterm-gui": "WezTerm",
        "wezterm": "WezTerm",
        "alacritty": "Alacritty",
        "kitty": "kitty",
        "hyper": "Hyper",
        "warp": "Warp",
        "code helper": "VS Code",
        "code": "VS Code",
        "cursor helper": "Cursor",
        "cursor": "Cursor",
    ]

    /// Which terminal hosts this process: walk up the parent chain until a known
    /// terminal turns up. `claude` usually sits under a shell, which sits under the
    /// terminal, so a couple of hops is normal.
    static func terminalApp(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<8 {
            let out = shell("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(current)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { return nil }

            // "  1234 /Applications/Ghostty.app/Contents/MacOS/ghostty"
            let parts = out.split(separator: " ", maxSplits: 1,
                                  omittingEmptySubsequences: true)
            guard parts.count == 2, let ppid = Int32(parts[0]) else { return nil }

            let name = (String(parts[1]) as NSString).lastPathComponent.lowercased()
            if let match = knownTerminals[name] { return match }

            guard ppid > 1 else { return nil }
            current = ppid
        }
        return nil
    }

    /// The controlling terminal of a process, e.g. "/dev/ttys003".
    static func tty(of pid: Int32) -> String? {
        let out = shell("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out != "??" else { return nil }
        return out.hasPrefix("/dev/") ? out : "/dev/\(out)"
    }

    static func workingDirectory(of pid: Int32) -> String? {
        let out = shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    // MARK: Transcript matching

    /// The `limit` most-recently-modified transcript session IDs for a working dir,
    /// skipping any session the hooks have already claimed.
    private static func recentSessionIDs(cwd: String, limit: Int,
                                         excluding known: Set<String>) -> [String] {
        let dir = projectsRoot.appendingPathComponent(encode(cwd))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        let jsonl = files.filter { $0.pathExtension == "jsonl" }
        func id(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

        let sorted = jsonl.sorted {
            // A hook-confirmed session owns its transcript outright, so those sort first
            // and can't be displaced by a more recently touched unknown file. Guesswork
            // is then confined to whatever slots are left.
            let ak = known.contains(id($0)), bk = known.contains(id($1))
            if ak != bk { return ak }

            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if a != b { return a > b }
            return $0.lastPathComponent > $1.lastPathComponent  // deterministic tie-break
        }
        return sorted.prefix(limit).map(id)
    }

    /// Claude encodes a project path by replacing every "/" with "-".
    private static func encode(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: Shell

    static func shell(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
