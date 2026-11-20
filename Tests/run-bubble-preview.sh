#!/bin/zsh
# Renders the speech bubble in its main moods to dist/bubble-preview.png for a visual check.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp /tmp/agentcats-bubble.XXXXXX)
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos14 -o "$BIN" Sources/Core/Models.swift Sources/Core/Summary.swift Sources/Core/Parsers.swift Sources/Core/Speech.swift Sources/App/SpeechBubble.swift Tests/Bubble/main.swift
mkdir -p dist
"$BIN"
