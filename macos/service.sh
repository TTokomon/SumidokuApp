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
    old_pid=$(launchctl print "$domain/$label" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')
    launchctl bootout "$domain/$label"
    # A GUI caller can return from bootout before the old runner exits. Wait
    # for that specific runner so its delayed cleanup cannot remove a new job.
    if [[ -n "$old_pid" ]]; then
      for attempt in {1..200}; do
        kill -0 "$old_pid" 2>/dev/null || return 0
        sleep 0.2
      done
      echo 'The old server is still stopping. Check logs before starting another instance.' >&2
      return 1
    fi
  fi
}
restart_server() {
  if ! launchctl print "$domain/$label" >/dev/null 2>&1; then start_server; return; fi
  old_pid=$(launchctl print "$domain/$label" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')
  # Keep the existing job registered. Its runner forwards TERM as server SIGINT,
  # and KeepAlive restarts it after graceful exit, without a bootstrap race.
  launchctl kill SIGTERM "$domain/$label"
  for attempt in {1..200}; do
    new_pid=$(launchctl print "$domain/$label" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }')
    if [[ -n "$new_pid" && "$new_pid" != "$old_pid" ]] && curl --silent --fail --max-time 1 http://127.0.0.1:3000/health >/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  echo 'The existing LaunchAgent did not restart in time. Inspect the server logs.' >&2
  return 1
}
case "${1:-status}" in
  start) start_server ;;
  stop) stop_server ;;
  restart) restart_server ;;
  status) launchctl print "$domain/$label" ;;
  open) open /Applications/Sumidoku.app ;;
  disable) stop_server; launchctl disable "$domain/$label" ;;
  enable) launchctl enable "$domain/$label"; start_server ;;
  *) echo 'Usage: service.sh start|stop|restart|status|open|disable|enable' >&2; exit 1 ;;
esac
