#!/bin/bash
#
# Build Claude Notch and install it as a real Mac app, so it no longer depends on
# Xcode being open. Safe to re-run: it replaces the installed copy in place and
# re-points the Claude Code hooks at whatever it just installed.
#
#   ./scripts/install.sh
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="ClaudeNotch"
# The bundle name must stay ClaudeNotch.app: HookInstaller identifies its own entries
# in ~/.claude/settings.json by the substring "ClaudeNotch.app/Contents/MacOS/ClaudeNotch".
# Rename it and old entries stop matching, so they'd be duplicated instead of replaced.
APP_NAME="ClaudeNotch.app"
BUILD_DIR="$PROJECT_DIR/build"
BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME"

# Build numbers come from the clock rather than the project file, so installing never
# has to rewrite project.pbxproj.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# PIDs of running *app* instances. The same binary also runs as the short-lived
# `--hook` client on every Claude Code event; killing one of those mid-flight would
# surface as a hook error, so they're filtered out.
#
# "No match" is the expected case here, but pgrep reports it as exit 1 and
# `set -o pipefail` promotes that to the whole pipeline — so without the `|| true`
# this function fails the script the moment nothing is running.
app_pids() {
    { pgrep -f "ClaudeNotch.app/Contents/MacOS/ClaudeNotch" 2>/dev/null || true; } | while read -r pid; do
        ps -o command= -p "$pid" 2>/dev/null | grep -q -- "--hook" || echo "$pid"
    done
}

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# --- where does it go -------------------------------------------------------------
if [ -w /Applications ]; then
    DEST_DIR="/Applications"
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
    warn "/Applications is not writable — installing to $DEST_DIR instead."
fi
DEST_APP="$DEST_DIR/$APP_NAME"
DEST_BIN="$DEST_APP/Contents/MacOS/ClaudeNotch"

bold "Building $SCHEME (Release, build $BUILD_NUMBER)…"
xcodebuild \
    -project "$PROJECT_DIR/ClaudeNotch.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build > "$BUILD_DIR/install-build.log" 2>&1 \
    || { tail -40 "$BUILD_DIR/install-build.log"; die "Build failed (full log: $BUILD_DIR/install-build.log)"; }

[ -d "$BUILT_APP" ] || die "Build succeeded but $BUILT_APP is missing."
ok "Built $BUILT_APP"

# --- stop whatever is running ------------------------------------------------------
# Whoever owns the hook socket answers this, whether it's the installed copy or a
# build running under Xcode. A hook blocked on a permission fails open when the
# socket closes, so this can't wedge a Claude Code session.
bold "Stopping any running instance…"
"$BUILT_APP/Contents/MacOS/ClaudeNotch" --quit >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    # Written as an `if` rather than `[ … ] && break`: when something *is* still
    # running the test returns 1, and under `set -e` that ends the script instead
    # of looping — which looked like install.sh dying right after the build.
    if [ -z "$(app_pids)" ]; then break; fi
    sleep 0.25
done
REMAINING="$(app_pids)"
if [ -n "$REMAINING" ]; then
    warn "Instance did not quit on request; forcing."
    # shellcheck disable=SC2086
    kill $REMAINING 2>/dev/null || true
    sleep 1
    REMAINING="$(app_pids)"
    # shellcheck disable=SC2086
    [ -n "$REMAINING" ] && kill -9 $REMAINING 2>/dev/null || true
    sleep 0.5
fi
REMAINING="$(app_pids)"
if [ -n "$REMAINING" ]; then
    # A build running under the Xcode debugger survives SIGKILL — only Xcode's Stop
    # button releases it. Installing still works; the two copies just coexist until then.
    warn "Still running (PIDs: $REMAINING). If that's an Xcode build, press ■ Stop in Xcode."
else
    ok "Nothing running"
fi

# --- install -----------------------------------------------------------------------
bold "Installing to ${DEST_APP}…"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
ok "Copied"

# --- point the hooks at this copy ---------------------------------------------------
# Run the installed binary so HookInstaller writes its own path into settings.json.
bold "Updating Claude Code hooks…"
"$DEST_BIN" --install-hooks
ok "~/.claude/settings.json now points at $DEST_BIN"

# --- launch -------------------------------------------------------------------------
bold "Launching…"
open "$DEST_APP"
sleep 2

# --- verify -------------------------------------------------------------------------
bold "Verification"
# Capture first, then parse: piping into an awk that exits early kills codesign with
# SIGPIPE, which `set -o pipefail` would treat as a failed verification.
CODESIGN_OUT="$(codesign -dv --verbose=2 "$DEST_APP" 2>&1 || true)"
AUTHORITY="$(printf '%s\n' "$CODESIGN_OUT" | sed -n 's/^Authority=//p' | head -n 1)"
[ -n "$AUTHORITY" ] && ok "Signed by: $AUTHORITY" || warn "Ad-hoc / unsigned — macOS will re-ask for permissions after each install."

VERSION="$(defaults read "$DEST_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
ok "Version $VERSION (build $BUILD_NUMBER)"

HOOK_COUNT="$(grep -c "$DEST_BIN" "$HOME/.claude/settings.json" 2>/dev/null || echo 0)"
if [ "$HOOK_COUNT" -ge 9 ]; then
    ok "$HOOK_COUNT hooks registered"
else
    warn "Only $HOOK_COUNT hook entries found — expected 9."
fi
if grep -q "DerivedData.*ClaudeNotch" "$HOME/.claude/settings.json" 2>/dev/null; then
    warn "settings.json still mentions a DerivedData build — check for stale entries."
else
    ok "No stale DerivedData entries"
fi

if [ -n "$(app_pids)" ]; then
    ok "Running from $DEST_APP"
else
    warn "App does not appear to be running — try opening it from $DEST_DIR."
fi

echo
bold "Done. Claude Notch runs on its own now — Xcode is no longer needed."
echo "  · Turn on Settings → Launch at login so it comes back after a restart."
echo "  · To develop: run from Xcode with NOTCH_TAKEOVER=1 in the scheme's environment,"
echo "    then re-run this script when you're done to restore the installed copy."
