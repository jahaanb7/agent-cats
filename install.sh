#!/bin/zsh
# Install the verified build into the user's Applications folder.
set -euo pipefail
cd "$(dirname "$0")"
SOURCE_APP=dist/AgentCats.app
[[ -x "$SOURCE_APP/Contents/MacOS/AgentCats" ]] || { print 'Run ./build.sh first.'; exit 1; }
codesign --verify --deep --strict "$SOURCE_APP"
mkdir -p "$HOME/Applications"
INSTALL_STAGE=$(mktemp -d "$HOME/Applications/.agentcats-install.XXXXXX")
trap 'rm -rf "$INSTALL_STAGE"' EXIT
ditto "$SOURCE_APP" "$INSTALL_STAGE/AgentCats.app"
codesign --verify --deep --strict "$INSTALL_STAGE/AgentCats.app"
DESTINATION="$HOME/Applications/AgentCats.app"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$INSTALL_STAGE/previous.app"; fi
if ! mv "$INSTALL_STAGE/AgentCats.app" "$DESTINATION"; then
  [[ ! -d "$INSTALL_STAGE/previous.app" ]] || mv "$INSTALL_STAGE/previous.app" "$DESTINATION"
  exit 1
fi
print "Installed $DESTINATION"
# Restart a running copy so the new build is the one in use (replacing files doesn't).
if pgrep -f "$DESTINATION/Contents/MacOS/AgentCats" >/dev/null; then
  osascript -e 'tell application id "local.agentcats.app" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -f "$DESTINATION/Contents/MacOS/AgentCats" >/dev/null || break; sleep 0.25; done
  pkill -f "$DESTINATION/Contents/MacOS/AgentCats" 2>/dev/null || true
  open "$DESTINATION" && print "Restarted Agent Cats"
fi
