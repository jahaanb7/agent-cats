#!/bin/zsh
# Builds the app icon from Sources/App/LogoArt.swift. Pass --preview for a size sheet in dist/logo/.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(mktemp /tmp/agentcats-icon.XXXXXX); trap 'rm -f "$BIN"' EXIT
swiftc -o "$BIN" Sources/App/LogoArt.swift Tools/Icon/main.swift
"$BIN" "$@"
