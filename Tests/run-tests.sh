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
  ClaudeNotch/Services/PermissionPolicy.swift
  ClaudeNotch/Services/PermissionRules.swift
  ClaudeNotch/Models/PermissionRequest.swift
  ClaudeNotch/Views/Theme.swift
  ClaudeNotch/Localization/Localization.swift
  ClaudeNotch/Localization/Strings.swift
)

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Building tests…"
swiftc -O -o "$BUILD_DIR/tests" Tests/main.swift "${SOURCES[@]}"

echo ""
"$BUILD_DIR/tests"
