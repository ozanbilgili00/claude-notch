# Claude Notch

A native macOS companion for [Claude Code](https://claude.com/claude-code) that lives in the MacBook notch (or at a screen edge on Macs without one). Built with SwiftUI and AppKit.

> **Unofficial.** Claude Notch is an independent hobby project. It is not affiliated with, endorsed by, or sponsored by Anthropic or Google.

## What it does

- Shows your live Claude Code sessions and what each one is doing.
- Lets you approve or deny tool calls from the notch (only when the session is in `default` permission mode).
- Usage rings, token counts and a daily summary.
- Optional monitoring of Gemini CLI (`agy`) sessions (read-only).
- Optional music panel with Spotify (you supply your own Spotify app client ID) and synced lyrics from [LRCLIB](https://lrclib.net).
- Multi-monitor support, Turkish and English UI.

## Requirements

- macOS 14 or later
- Xcode 15 or later (to build)
- Claude Code installed

## Build and install

```bash
git clone https://github.com/ozanbilgili00/claude-notch
cd claude-notch
./scripts/install.sh
```

The script builds a Release copy, installs it to `/Applications` (or `~/Applications`), and registers the hooks. To remove everything:

```bash
./scripts/uninstall.sh
```

The bundle identifier is `com.ozan.ClaudeNotch`. If you sign with your own team, change it in the Xcode project.

Run the tests with `Tests/run-tests.sh`.

## What it changes on your machine

Please read this before installing.

- **Claude Code hooks.** The installer adds entries to `~/.claude/settings.json` so Claude Code reports events to the app. `uninstall.sh` removes them again.
- **Local socket.** The app listens on a Unix socket at `~/Library/Application Support/ClaudeNotch/notch.sock` (directory `0700`, socket `0600`). Hook events and approval decisions travel over it.
- **Keychain access.** To show plan usage, the app reads the OAuth token that Claude Code stores in your Keychain (`Claude Code-credentials`) and calls `https://api.anthropic.com/api/oauth/usage`. This endpoint is **undocumented** and may change or stop working at any time. The token is only used for that request and is never logged or sent anywhere else. You will see a Keychain prompt the first time.
- **Network.** Besides the usage call, the app only talks to Spotify (if you connect it) and LRCLIB (lyrics).

## Trademarks

"Claude" and the Claude logo are trademarks of Anthropic. "Gemini" and the Gemini star are trademarks of Google. They are used here only to refer to those products, and the mascot artwork is a fan-made interpretation. If you fork this project, consider replacing the artwork and the name.

## License

[MIT](LICENSE)
