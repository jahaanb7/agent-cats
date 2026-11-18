#!/bin/zsh
# Renders the dashboard with sample sessions to dist/dashboard-preview.png for a visual check.
# Pass --empty or --no-hooks to see those states.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp /tmp/agentcats-dashboard.XXXXXX)
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos14 -o "$BIN" Sources/Shared/*.swift Sources/Core/*.swift \
  $(ls Sources/App/*.swift | grep -v '/main.swift$') Tests/Dashboard/main.swift
mkdir -p dist
"$BIN" "$@"
