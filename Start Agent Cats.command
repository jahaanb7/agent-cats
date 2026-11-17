#!/bin/zsh
# Double-click from Finder to launch in the user's real desktop session.
set -u
PROJECT_DIR=${0:A:h}
APP_PATH="$HOME/Applications/AgentCats.app"
[[ -x "$APP_PATH/Contents/MacOS/AgentCats" ]] || APP_PATH="$PROJECT_DIR/dist/AgentCats.app"
if [[ ! -x "$APP_PATH/Contents/MacOS/AgentCats" ]]; then
  print 'Agent Cats is not built. Run ./build.sh in the project folder.'
  read 'reply?Press Return to close.'
  exit 1
fi
LOG_DIR="$HOME/Library/Logs/AgentCats"
mkdir -p "$LOG_DIR"
nohup "$APP_PATH/Contents/MacOS/AgentCats" >> "$LOG_DIR/launch.log" 2>&1 &
AGENTCATS_PID=$!
sleep 2
if kill -0 "$AGENTCATS_PID" 2>/dev/null; then
  print 'Agent Cats is running. Look for the cat room below the top-right menu bar.'
else
  wait "$AGENTCATS_PID"
  RESULT=$?
  if [[ "$RESULT" -eq 0 ]]; then
    print 'Asked the existing Agent Cats window to appear.'
  else
    print "Agent Cats could not start (exit $RESULT). Diagnostics: $LOG_DIR"
    tail -n 8 "$LOG_DIR/launch.log"
    read 'reply?Press Return to close.'
    exit "$RESULT"
  fi
fi
