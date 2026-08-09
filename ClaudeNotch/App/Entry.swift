import SwiftUI

/// Process entry point. The same binary doubles as the Claude Code hook client:
/// when launched with `--hook <event>`, it does a fast stdin→socket→stdout round-trip
/// and exits without ever touching AppKit/SwiftUI. Otherwise it boots the UI app.
@main
struct Entry {
    @MainActor
    static func main() {
        // Never let a broken socket write (a hook client that disconnected early) raise
        // SIGPIPE — that would crash the app in production and freeze it under the Xcode
        // debugger, stalling every hook. Ignore it process-wide instead.
        signal(SIGPIPE, SIG_IGN)

        let args = CommandLine.arguments
        if args.contains("--hook") {
            HookMode.run()
            return
        }
        if args.contains("--install-hooks") {
            do { try HookInstaller.install(); print(L(.cliHooksInstalled)) }
            catch { print(L(.cliInstallFailed, "\(error)")); exit(1) }
            return
        }
        if args.contains("--uninstall-hooks") {
            do { try HookInstaller.uninstall(); print(L(.cliHooksRemoved)) }
            catch { print(L(.cliUninstallFailed, "\(error)")); exit(1) }
            return
        }
        // Answer a pending permission from the CLI: --resolve <allowOnce|alwaysAllow|deny> [session]
        if let idx = args.firstIndex(of: "--resolve") {
            let decision = idx + 1 < args.count ? args[idx + 1] : ""
            let session = idx + 2 < args.count ? args[idx + 2] : ""
            let msg: [String: Any] = ["control": "resolve", "decision": decision, "session": session]
            let data = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
            let reply = UnixSocket.request(data)
            print("resolve \(decision): \(reply.map { "\($0)" } ?? "no response")")
            return
        }
        // Ask a running instance to quit (used by scripts/install.sh before replacing it).
        if args.contains("--quit") {
            let reply = UnixSocket.sendControl("quit")
            print(reply == nil ? "no instance running" : "quit requested")
            return
        }

        guard claimSingleInstance() else { return }
        ClaudeNotchApp.main()
    }

    /// Only one copy may own the hook socket. Since the app is invisible by design, two
    /// copies fighting over it is silent and confusing: the last one to launch used to
    /// win, so hooks would reach a build you didn't think was running.
    ///
    /// Returns false when this process should bow out.
    @MainActor
    private static func claimSingleInstance() -> Bool {
        guard let running = UnixSocket.probeRunningInstance() else { return true }
        let otherPath = running["path"] as? String ?? "unknown"

        // Development builds take over deliberately; otherwise launching a second copy
        // behaves like launching any Mac app twice — the running one comes forward.
        guard ProcessInfo.processInfo.environment["NOTCH_TAKEOVER"] == "1" else {
            UnixSocket.sendControl("show")
            fputs(L(.cliAlreadyRunning, otherPath) + "\n", stderr)
            return false
        }

        fputs("NOTCH_TAKEOVER: asking \(otherPath) to quit…\n", stderr)
        UnixSocket.sendControl("quit")
        // Wait for it to release the socket rather than racing it to bind.
        for _ in 0..<30 {
            if UnixSocket.probeRunningInstance(timeout: 0.3) == nil { return true }
            usleep(100_000)
        }
        fputs("NOTCH_TAKEOVER: previous instance didn't quit; taking the socket anyway.\n", stderr)
        return true
    }
}
