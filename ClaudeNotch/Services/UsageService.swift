import Foundation
import Security

/// Fetches live 5-hour / 7-day usage from the same endpoint Claude Code's `/usage`
/// command uses, authenticated with the OAuth token in the login Keychain. Polls
/// periodically and updates `SessionStore.usage`. Falls back silently (isLive=false)
/// if the token or endpoint isn't available.
final class UsageService: @unchecked Sendable {
    private let store: SessionStore
    private var timer: Timer?

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let keychainService = "Claude Code-credentials"

    init(store: SessionStore) {
        self.store = store
    }

    @MainActor func start() {
        refresh()
        // Poll every 2 minutes; usage windows move slowly.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @MainActor func refresh() {
        Task.detached { [weak self] in
            guard let self else { return }
            let dbg = ProcessInfo.processInfo.environment["NOTCH_DEBUG"] != nil
            guard let token = self.readToken() else {
                if dbg { fputs("[usage] Keychain token okunamadı\n", stderr) }
                return
            }
            if dbg { fputs("[usage] token OK (len=\(token.count)), fetch ediliyor\n", stderr) }
            guard let snapshot = await self.fetch(token: token) else {
                if dbg { fputs("[usage] fetch başarısız\n", stderr) }
                return
            }
            if dbg { fputs("[usage] 5h=\(snapshot.fiveHour) 7d=\(snapshot.sevenDay)\n", stderr) }
            await MainActor.run {
                self.store.usage.fiveHourPercent = snapshot.fiveHour
                self.store.usage.fiveHourResetsAt = snapshot.fiveHourResets
                self.store.usage.weeklyPercent = snapshot.sevenDay
                self.store.usage.weeklyResetsAt = snapshot.sevenDayResets
                self.store.usage.opusPercent = snapshot.opus
                self.store.usage.opusResetsAt = snapshot.opusResets
                self.store.usage.extraCreditsUsed = snapshot.extraUsed
                self.store.usage.extraCreditsLimit = snapshot.extraLimit
                self.store.usage.severity = snapshot.severity
                self.store.usage.isLive = true
            }
        }
    }

    // MARK: Fetch

    private struct Parsed {
        var fiveHour: Double, fiveHourResets: Date?
        var sevenDay: Double, sevenDayResets: Date?
        var opus: Double?, opusResets: Date?
        var extraUsed: Double?, extraLimit: Double?
        var severity: String?
    }

    private func fetch(token: String) async -> Parsed? {
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-notch", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func window(_ key: String) -> (Double, Date?) {
            guard let w = json[key] as? [String: Any] else { return (0, nil) }
            let pct = (w["utilization"] as? Double) ?? 0
            return (pct / 100.0, (w["resets_at"] as? String).flatMap(Self.resetDate))
        }
        let five = window("five_hour")
        let seven = window("seven_day")

        // Opus gets its own weekly window on some plans and is absent (null) on others.
        var opus: (Double, Date?)?
        if json["seven_day_opus"] is [String: Any] { opus = window("seven_day_opus") }

        // Extra credits only exist once the user switches them on.
        var extraUsed: Double?, extraLimit: Double?
        if let extra = json["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true {
            extraUsed = extra["used_credits"] as? Double
            extraLimit = extra["monthly_limit"] as? Double
        }

        // `limits[]` carries the API's own severity per window; take the worst one.
        let order = ["normal": 0, "warning": 1, "critical": 2, "exceeded": 3]
        let severity = (json["limits"] as? [[String: Any]])?
            .compactMap { $0["severity"] as? String }
            .max { (order[$0] ?? 0) < (order[$1] ?? 0) }

        return Parsed(fiveHour: five.0, fiveHourResets: five.1,
                      sevenDay: seven.0, sevenDayResets: seven.1,
                      opus: opus?.0, opusResets: opus?.1,
                      extraUsed: extraUsed, extraLimit: extraLimit,
                      severity: severity)
    }

    // MARK: Keychain

    /// Reads the OAuth access token from the login Keychain. Uses the `security` CLI
    /// (already trusted for this item) rather than SecItemCopyMatching, so an unsigned
    /// dev build doesn't trigger a per-app Keychain confirmation dialog.
    private func readToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        return token
    }

    // MARK: Countdown formatting

    /// "2026-07-23T19:50:00+00:00" → the reset date. Rendering it as a countdown is the
    /// view's job (see `UsageSnapshot.countdown`), so it stays current between fetches.
    static func resetDate(from iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso)
            ?? { let f = ISO8601DateFormatter(); return f.date(from: iso) }()
        return date
    }
}
