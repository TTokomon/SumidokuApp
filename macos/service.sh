#!/bin/bash
set -eu
label=app.sumidoku.server
domain="gui/$(id -u)"
plist="$HOME/Library/LaunchAgents/$label.plist"
wait_ready() {
  for attempt in {1..100}; do
    if curl --silent --fail --max-time 1 http://127.0.0.1:3000/health >/dev/null; then return 0; fi
    sleep 0.2
  done
  echo 'Sumidoku did not become ready; inspect Library/Logs/Sumidoku.' >&2
  return 1
}
start_server() {
  if launchctl print "$domain/$label" >/dev/null 2>&1; then wait_ready; return; fi
  # bootout can return before launchd has fully released the old service label.
  for attempt in {1..50}; do
    if launchctl bootstrap "$domain" "$plist" 2>/dev/null; then wait_ready; return; fi
    sleep 0.2
  done
  launchctl bootstrap "$domain" "$plist"
}
stop_server() {
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$label"
  fi
}
case "${1:-status}" in
  start) start_server ;;
  stop) stop_server ;;
  restart) stop_server; start_server ;;
  status) launchctl print "$domain/$label" ;;
  open) open -a Safari http://localhost:3000 ;;
  disable) stop_server; launchctl disable "$domain/$label" ;;
  enable) launchctl enable "$domain/$label"; start_server ;;
  *) echo 'Usage: service.sh start|stop|restart|status|open|disable|enable' >&2; exit 1 ;;
esac
