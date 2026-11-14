#!/bin/bash
# Unit tests for Claude Notch's pure logic.
#
# Deliberately not an Xcode test target: adding one means hand-editing
# project.pbxproj, which previously dropped the app's productReference and broke ⌘R.
# Instead we compile the dependency-free sources together with Tests/main.swift.
#
# Only sources free of AppKit/app-lifecycle dependencies can be listed here; SwiftUI is
# fine (Theme is pulled in because PermissionRequest tints its risk levels).

set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(
  ClaudeNotch/Services/PromptText.swift
  ClaudeNotch/Services/TranscriptParser.swift
  ClaudeNotch/Models/TokenCounts.swift
  ClaudeNotch/Services/LineDelta.swift
  ClaudeNotch/Services/DailyLog.swift
  ClaudeNotch/Services/LedgerState.swift
  ClaudeNotch/Models/Session.swift
  ClaudeNotch/Models/Question.swift
  ClaudeNotch/Models/ConversationTurn.swift
  ClaudeNotch/Models/ActivityKind.swift
  ClaudeNotch/Services/PermissionPolicy.swift
  ClaudeNotch/Services/PermissionRules.swift
  ClaudeNotch/Models/PermissionRequest.swift
  ClaudeNotch/Views/Theme.swift
  ClaudeNotch/Views/ThemeSettings.swift
  ClaudeNotch/Localization/Localization.swift
  ClaudeNotch/Localization/Strings.swift
  ClaudeNotch/Models/SpotifyTrack.swift
  ClaudeNotch/Models/ShelfItem.swift
  ClaudeNotch/Services/LyricsService.swift
  ClaudeNotch/Services/SpotifyService.swift
  ClaudeNotch/Services/AppleScriptRunner.swift
  ClaudeNotch/Services/ArtworkLoader.swift
  ClaudeNotch/Services/SpotifyWebAPI.swift
  ClaudeNotch/Services/SpotifyAuth.swift
  ClaudeNotch/App/AppInfo.swift
  ClaudeNotch/Services/UnixSocket.swift
  ClaudeNotch/Services/CoreAudioBridge.swift
  ClaudeNotch/Notch/EdgeGeometry.swift
  ClaudeNotch/Notch/ScreenPicker.swift
  ClaudeNotch/Settings/Preferences.swift
  ClaudeNotch/Models/UsageRingKind.swift
  ClaudeNotch/Models/UsageSnapshot.swift
  ClaudeNotch/Services/UsageAlerts.swift
  ClaudeNotch/Models/SessionStatus.swift
  ClaudeNotch/Services/ProcessTapMixer.swift
  ClaudeNotch/Services/GeminiTranscript.swift
  ClaudeNotch/Services/GeminiDiscovery.swift
  ClaudeNotch/Services/SessionDiscovery.swift
)

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Building tests…"
swiftc -O -o "$BUILD_DIR/tests" Tests/main.swift "${SOURCES[@]}"

echo ""
"$BUILD_DIR/tests"
