import Foundation

/// Finds running Gemini sessions — the Antigravity CLI, `agy` — and the work Claude has
/// handed to Gemini through gemini-mcp, which is `agy` running headless inside a job's
/// sandboxed copy of the project.
///
/// A live conversation is the `presence/<conversation-id>.lock` file an `agy` process
/// holds open; its transcript is under `brain/<id>/`. Gemini.app's background service
/// (`agy --hub`) holds many conversations at once and is not a terminal session, so it
/// is left out.
enum GeminiDiscovery {
    struct Found: Sendable, Equatable {
        let id: String              // agy conversation id
        let cwd: String             // the real project, also for a delegated job
        let pid: Int32
        let tty: String?
        let terminalApp: String?
        let transcriptPath: String
        /// Set when Claude delegated this work through gemini-mcp.
        let job: Job?
    }

    /// What gemini-mcp's job folder says about a delegated run.
    struct Job: Sendable, Equatable {
        let id: String
        let task: String?
        let model: String?
    }

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli")
    static let jobsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/gemini-mcp/jobs")

    static func transcriptPath(for id: String) -> String {
        root.appendingPathComponent("brain/\(id)/.system_generated/logs/transcript.jsonl").path
    }

    static func scan() -> [Found] {
        let pids = SessionDiscovery.shell("/usr/bin/pgrep", ["-x", "agy"])
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }

        return pids.compactMap { pid -> Found? in
            let args = SessionDiscovery.shell("/bin/ps", ["-o", "args=", "-p", "\(pid)"])
            guard !args.contains("--hub") else { return nil }

            let files = SessionDiscovery.shell("/usr/sbin/lsof", ["-p", "\(pid)", "-Fn"])
            guard let open = openFiles(files), let id = open.conversation else { return nil }

            let job = jobID(forWorkspace: open.cwd).map(loadJob)
            let cwd = job.flatMap { jobCwd($0.id) } ?? open.cwd
            return Found(id: id, cwd: cwd, pid: pid,
                         tty: SessionDiscovery.tty(of: pid),
                         terminalApp: SessionDiscovery.terminalApp(of: pid),
                         transcriptPath: transcriptPath(for: id), job: job)
        }
    }

    /// The model `agy` starts with, from its settings ("Gemini 4 Argon (Low)").
    static func defaultModel() -> String? {
        let url = root.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj["model"] as? String
    }

    // MARK: Pure

    /// Out of `lsof -Fn` output: the working directory and the conversation whose
    /// presence lock is open. The output is field lines — `f<fd>` then `n<path>`.
    static func openFiles(_ lsof: String) -> (cwd: String, conversation: String?)? {
        var fd = ""
        var cwd: String?
        var conversation: String?
        for line in lsof.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("f") { fd = String(line.dropFirst()); continue }
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            if fd == "cwd" { cwd = path }
            if path.contains("/antigravity-cli/presence/"), path.hasSuffix(".lock") {
                conversation = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            }
        }
        guard let cwd else { return nil }
        return (cwd, conversation)
    }

    /// `~/.cache/gemini-mcp/jobs/<id>/ws[/…]` → `<id>`; nil for any other directory.
    static func jobID(forWorkspace path: String, jobsRoot: String = jobsRoot.path) -> String? {
        let prefix = jobsRoot.hasSuffix("/") ? jobsRoot : jobsRoot + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 2)
        guard parts.count >= 2, parts[1] == "ws", !parts[0].isEmpty else { return nil }
        return String(parts[0])
    }

    /// The first line of a delegated prompt that says what the job is, skipping the
    /// working rules gemini-mcp may put first.
    static func taskLine(_ prompt: String) -> String? {
        let body = prompt.range(of: "GÖREV:\n").map { String(prompt[$0.upperBound...]) } ?? prompt
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(200)) }
    }

    // MARK: Job folder

    private static func meta(_ id: String) -> [String: Any]? {
        let url = jobsRoot.appendingPathComponent("\(id)/meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jobCwd(_ id: String) -> String? {
        meta(id)?["cwd"] as? String
    }

    private static func loadJob(_ id: String) -> Job {
        let m = meta(id)
        let models = m?["models"] as? [String] ?? []
        let index = m?["modelIndex"] as? Int ?? 0
        let prompt = try? String(contentsOf: jobsRoot.appendingPathComponent("\(id)/prompt.txt"),
                                 encoding: .utf8)
        return Job(id: id, task: prompt.flatMap(taskLine),
                   model: models.indices.contains(index) ? models[index] : models.first)
    }
}
