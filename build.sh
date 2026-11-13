#!/bin/zsh
# Builds with swiftc directly: this Mac has Command Line Tools only (no Xcode), where `swift build` is unreliable.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14)
swiftc "${FLAGS[@]}" -module-name AgentCats -o dist/agentcats Sources/Shared/*.swift Sources/Core/*.swift Sources/CLI/*.swift
swiftc "${FLAGS[@]}" -module-name AgentCatsHook -o dist/agentcats-hook Sources/Shared/*.swift Sources/Hook/main.swift
echo "built dist/agentcats dist/agentcats-hook"
