#!/bin/zsh
# Stage the complete build before replacing the runnable app.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist
BUILD_DIR=$(mktemp -d dist/.agentcats-build.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14)
swiftc "${FLAGS[@]}" -module-name AgentCats -o "$BUILD_DIR/agentcats" Sources/Shared/*.swift Sources/Core/*.swift Sources/CLI/*.swift
swiftc "${FLAGS[@]}" -module-name AgentCatsHook -o "$BUILD_DIR/agentcats-hook" Sources/Shared/*.swift Sources/Hook/main.swift
APP="$BUILD_DIR/AgentCats.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -module-name AgentCatsApp -o "$APP/Contents/MacOS/AgentCats" \
  Sources/Shared/*.swift Sources/Core/*.swift Sources/App/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Art/cats.json "$APP/Contents/Resources/cats.json"
cp "$BUILD_DIR/agentcats-hook" "$APP/Contents/MacOS/agentcats-hook"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
# A compile/signing failure leaves the previous app intact.
if [[ -d dist/AgentCats.app ]]; then mv dist/AgentCats.app "$BUILD_DIR/previous.app"; fi
if ! mv "$APP" dist/AgentCats.app; then
  [[ ! -d "$BUILD_DIR/previous.app" ]] || mv "$BUILD_DIR/previous.app" dist/AgentCats.app
  exit 1
fi
mv "$BUILD_DIR/agentcats" dist/agentcats
mv "$BUILD_DIR/agentcats-hook" dist/agentcats-hook
echo "built dist/agentcats dist/agentcats-hook dist/AgentCats.app"
