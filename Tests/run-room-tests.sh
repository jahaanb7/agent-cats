#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BINARY=$(mktemp /tmp/agentcats-room-tests.XXXXXX)
trap 'rm -f "$TEST_BINARY"' EXIT
swiftc -swift-version 5 -o "$TEST_BINARY" Sources/Shared/ProcInfo.swift Sources/Core/Models.swift Sources/Core/Summary.swift Sources/Core/Parsers.swift Sources/Core/TreeLayout.swift Sources/App/TerminalJump.swift Sources/App/Sprites.swift Sources/App/CatTreeView.swift Sources/App/CatRoomView.swift Sources/App/PixelFont.swift Tests/Room/main.swift
mkdir -p dist
"$TEST_BINARY"
