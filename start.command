#!/bin/bash
# Double-click this file to start IntroPlayer.
# It launches the local server and opens your browser.

cd "$(dirname "$0")"

# Pick whichever python is available
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo ""
  echo "  Python is not installed yet."
  echo "  Open Terminal and run:   xcode-select --install"
  echo "  then double-click this file again."
  echo ""
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi

# Open browser a moment after the server starts
( sleep 1.5 ; open "http://localhost:8000" ) &

"$PY" server.py
