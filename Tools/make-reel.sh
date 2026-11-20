#!/bin/zsh
# Renders the promo reel (voiceover, music, sound effects) to dist/agent-cats-reel.mp4. Needs ffmpeg.
# REEL_VOICE=Daniel picks another `say` voice; REEL_VO_DIR=folder uses your own recordings (0.wav … 7.wav).
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -I Tools/make_reel.py "$@"
