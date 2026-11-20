#!/bin/zsh
# Renders the promo reel from the app's own views to dist/agent-cats-reel.mp4 (1080×1920, 30fps).
# Needs ffmpeg (brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/agentcats-reel.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 5 -target arm64-apple-macos14 -o "$WORK/reel" Sources/Shared/*.swift Sources/Core/*.swift \
  $(ls Sources/App/*.swift | grep -v '/main.swift$') Tools/Reel/main.swift
"$WORK/reel" "$WORK/frames"
mkdir -p dist
ffmpeg -loglevel error -y -framerate 30 -i "$WORK/frames/f%04d.png" -c:v libx264 -pix_fmt yuv420p -crf 18 \
  -movflags +faststart dist/agent-cats-reel.mp4
echo "dist/agent-cats-reel.mp4"
