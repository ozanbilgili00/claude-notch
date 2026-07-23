import Foundation

/// Runs when the binary is invoked as a Claude Code hook (`--hook <Event>`).
/// Reads the hook JSON from stdin, forwards it to the running app over the unix socket,
/// waits for a decision, and writes the hook's JSON response to stdout.
///
/// Fail-open by design: if the app isn't running or anything goes wrong, we exit 0 with
/// no stdout, which tells Claude Code to proceed with its normal interactive behavior.
/// Installing the hook can therefore never block or break a session.
enum HookMode {
    static func run() {
        let args = CommandLine.arguments
        let eventArg = args.firstIndex(of: "--hook").flatMap { idx -> String? in
            idx + 1 < args.count ? args[idx + 1] : nil
        } ?? "Unknown"

        let stdinData = FileHandle.standardInput.readDataToEndOfFile()

        // Parse the payload so we can forward it as a nested object; tolerate junk.
        let payload = (try? JSONSerialization.jsonObject(with: stdinData)) ?? [:]
        let event = (payload as? [String: Any])?["hook_event_name"] as? String ?? eventArg

        let wire: [String: Any] = ["event": event, "payload": payload]
        guard let wireData = try? JSONSerialization.data(withJSONObject: wire) else {
            exit(0)
        }

        // Only PreToolUse can legitimately block (waiting for a notch permission or
        // question answer); every other hook must return quickly or fail open, so it can
        // never delay Claude Code — even if the app is busy or restarting.
        let timeout: TimeInterval = (event == "PreToolUse") ? 600 : 4
        guard let reply = UnixSocket.request(wireData, timeout: timeout) else { exit(0) }

        if let stdout = reply["stdout"] as? String, !stdout.isEmpty {
            FileHandle.standardOutput.write(Data(stdout.utf8))
        }
        let code = (reply["exitCode"] as? Int).map { Int32($0) } ?? 0
        exit(code)
    }
}
