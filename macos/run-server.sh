#!/bin/bash
set -eu
DATA="$HOME/Library/Application Support/Sumidoku"
"$DATA/bin/sumidoku-server" --config-dir "$DATA" &
server_pid=$!
stop_server() {
  trap '' TERM INT
  kill -INT "$server_pid" 2>/dev/null || true
  wait "$server_pid" || true
  exit 0
}
trap stop_server TERM INT
wait "$server_pid"
