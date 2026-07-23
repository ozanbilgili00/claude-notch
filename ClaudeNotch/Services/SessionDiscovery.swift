import Foundation

/// Discovers Claude Code sessions that are running but haven't fired a hook yet (e.g.
/// idle sessions, or sessions that were already open when the notch launched). Works by
/// finding running `claude` CLI processes, resolving each one's working directory, and
/// matching it to the most-recent transcript(s) in that project's folder.
enum SessionDiscovery {
    struct Found: Sendable { let id: String; let cwd: String; let pid: Int32; let tty: String? }

    static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    static func scan() -> [Found] {
        let procs = claudeProcesses()
        guard !procs.isEmpty else { return [] }

        // Group running processes by working directory.
        var byCwd: [String: [(pid: Int32, tty: String?)]] = [:]
        for p in procs {
            if let cwd = workingDirectory(of: p.pid) { byCwd[cwd, default: []].append(p) }
        }

        var found: [Found] = []
        for (cwd, list) in byCwd {
            let ids = recentSessionIDs(cwd: cwd, limit: list.count)
            // One session per running process; pairing is exact when a directory has a
            // single session (the common case), approximate when several share a folder.
            for (i, id) in ids.enumerated() {
                let proc = list[min(i, list.count - 1)]
                found.append(Found(id: id, cwd: cwd, pid: proc.pid, tty: proc.tty))
            }
        }
        return found
    }

    // MARK: Process inspection

    private static func claudeProcesses() -> [(pid: Int32, tty: String?)] {
        // `pgrep -x claude` matches the CLI process exactly (not the desktop app or us).
        let out = shell("/usr/bin/pgrep", ["-x", "claude"])
        return out.split(whereSeparator: \.isNewline).compactMap { line in
            guard let pid = Int32(line) else { return nil }
            return (pid, tty(of: pid))
        }
    }

    /// The controlling terminal of a process, e.g. "/dev/ttys003".
    private static func tty(of pid: Int32) -> String? {
        let out = shell("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, out != "??" else { return nil }
        return out.hasPrefix("/dev/") ? out : "/dev/\(out)"
    }

    private static func workingDirectory(of pid: Int32) -> String? {
        let out = shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    // MARK: Transcript matching

    /// The `limit` most-recently-modified transcript session IDs for a working dir.
    private static func recentSessionIDs(cwd: String, limit: Int) -> [String] {
        let dir = projectsRoot.appendingPathComponent(encode(cwd))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        let jsonl = files.filter { $0.pathExtension == "jsonl" }
        let sorted = jsonl.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if a != b { return a > b }
            return $0.lastPathComponent > $1.lastPathComponent  // deterministic tie-break
        }
        return sorted.prefix(limit).map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Claude encodes a project path by replacing every "/" with "-".
    private static func encode(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: Shell

    private static func shell(_ launchPath: String, _ args: [String]) -> String {
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
