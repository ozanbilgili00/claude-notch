#!/bin/bash
#
# Remove the installed Claude Notch: hooks out of ~/.claude/settings.json, login item
# deregistered, app deleted. Your Claude Code sessions are untouched.
#
#   ./scripts/uninstall.sh
#
set -euo pipefail

APP_NAME="ClaudeNotch.app"
bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

DEST_APP=""
for dir in /Applications "$HOME/Applications"; do
    [ -d "$dir/$APP_NAME" ] && DEST_APP="$dir/$APP_NAME" && break
done

if [ -n "$DEST_APP" ]; then
    bold "Removing hooks…"
    "$DEST_APP/Contents/MacOS/ClaudeNotch" --uninstall-hooks || warn "Could not remove hooks; edit ~/.claude/settings.json by hand."

    bold "Quitting…"
    "$DEST_APP/Contents/MacOS/ClaudeNotch" --quit >/dev/null 2>&1 || true
    sleep 1
    pkill -f "$APP_NAME/Contents/MacOS/ClaudeNotch" 2>/dev/null || true

    bold "Deleting ${DEST_APP}…"
    rm -rf "$DEST_APP"
    ok "Removed"
else
    warn "No installed copy found in /Applications or ~/Applications."
fi

# The login item is registered against the bundle; clearing it needs the app, so do it
# on a best-effort basis and tell the user where to look if it lingers.
if [ -n "$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -i "claude notch" || true)" ]; then
    warn "A login item may remain — System Settings → General → Login Items."
fi

# The hook socket lives outside the bundle.
rm -f "$HOME/Library/Application Support/ClaudeNotch/notch.sock"
ok "Socket cleaned up"

echo
bold "Uninstalled. Preferences remain in ~/Library/Preferences/com.ozan.ClaudeNotch.plist"
echo "  Delete them with: defaults delete com.ozan.ClaudeNotch"
