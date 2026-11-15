#!/bin/bash
set -eu
DATA="${1:-$HOME/Library/Application Support/Sumidoku}"
BIN=$(cd "$(dirname "$0")" && pwd)
SERVER_EXECUTABLE="${2:-$BIN/sumidoku-server}"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$SERVER_EXECUTABLE" --config-dir "$DATA" &
server_pid=$!
stop_server() {
  trap '' TERM INT
  kill -INT "$server_pid" 2>/dev/null || true
  wait "$server_pid" || true
  exit 0
}
trap stop_server TERM INT
wait "$server_pid"
