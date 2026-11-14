import Foundation

/// Runs AppleScript by shelling out to `/usr/bin/osascript`.
///
/// Deliberately a child process rather than `NSAppleScript`: this app builds with
/// `ENABLE_HARDENED_RUNTIME = YES` and ships no entitlements file, so sending Apple
/// Events from inside the process would need `com.apple.security.automation.apple-events`.
/// Going through `osascript` sidesteps that, and it is also what attributes the one-time
/// Automation consent prompt to Claude Notch rather than to some helper.
enum AppleScriptRunner {

    /// Runs `source` and returns its trimmed stdout, or nil if anything went wrong —
    /// a launch failure, a non-zero exit, undecodable output, or the timeout below.
    ///
    /// The timeout matters: an app that is mid-launch (Spotify is a repeat offender) can
    /// leave `osascript` blocked on an Apple Event reply indefinitely, and this reads the
    /// pipe synchronously. Without the watchdog a single hung script would wedge whichever
    /// thread called it, forever.
    ///
    /// The default is deliberately generous. The *first* Apple Event to a given app puts
    /// macOS's Automation consent dialog on screen and blocks until it is answered — a
    /// short watchdog would kill the script while the user is still reaching for the
    /// mouse, so the permission could never be granted at all. Callers that are polling
    /// something already approved should pass a small timeout explicitly.
    @discardableResult
    static func run(_ source: String, timeout: TimeInterval = 25) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }

        // Fires only if the script is still running when the deadline passes; cancelled
        // below on the normal path so a finished script never gets a stray terminate().
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escapes a value for interpolation into a double-quoted AppleScript string literal.
    static func quote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
