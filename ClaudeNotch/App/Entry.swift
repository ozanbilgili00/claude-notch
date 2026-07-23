import SwiftUI

/// Process entry point. The same binary doubles as the Claude Code hook client:
/// when launched with `--hook <event>`, it does a fast stdin→socket→stdout round-trip
/// and exits without ever touching AppKit/SwiftUI. Otherwise it boots the UI app.
@main
struct Entry {
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
            do { try HookInstaller.install(); print("Claude Notch hooks installed.") }
            catch { print("Install failed: \(error)"); exit(1) }
            return
        }
        if args.contains("--uninstall-hooks") {
            do { try HookInstaller.uninstall(); print("Claude Notch hooks removed.") }
            catch { print("Uninstall failed: \(error)"); exit(1) }
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
        ClaudeNotchApp.main()
    }
}
