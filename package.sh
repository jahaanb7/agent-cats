#!/bin/zsh
# Builds a release zip people can download: dist/AgentCats-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
OUT="dist/AgentCats-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent dist/AgentCats.app "$OUT"
shasum -a 256 "$OUT"
echo "packaged $OUT"
