#!/usr/bin/env bash
# Stops the demo started by scripts/demo.sh: the API and the UI dev server, with their child processes. The database
# container keeps running (docker compose stop db stops it too); the demo database stays until the next scripts/demo.sh.
set -uo pipefail
cd "$(dirname "$0")/.."

stop() {
  local name="$1" file=".demo/$1.pid"
  [ -f "$file" ] || { echo "$name: not running (no $file)"; return; }
  local pid
  pid=$(cat "$file")
  if [ -r "/proc/$pid/winpid" ]; then
    # Git Bash on Windows: stop the Windows process and its whole tree (npm leaves node children otherwise)
    taskkill //PID "$(cat "/proc/$pid/winpid")" //T //F >/dev/null 2>&1 && echo "$name: stopped" || echo "$name: already stopped"
  elif kill -0 "$pid" 2>/dev/null; then
    pkill -TERM -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null && echo "$name: stopped"
  else
    echo "$name: already stopped"
  fi
  rm -f "$file"
}
stop ui
stop api
