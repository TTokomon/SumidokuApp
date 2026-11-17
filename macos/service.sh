#!/bin/bash
set -eu
label=app.sumidoku.server
server_port=3000
service_home="$HOME"
if [[ $# == 4 ]]; then
  service_home=$2; label=$3; server_port=$4
  [[ "$label" == app.sumidoku.fixture.* && "$service_home" == */sumidoku-community-e2e-*/Home && "$server_port" =~ ^[0-9]+$ && "$server_port" != 3000 ]] || exit 2
elif [[ $# != 1 ]]; then exit 2
fi
domain="gui/$(id -u)"
plist="$service_home/Library/LaunchAgents/$label.plist"
wait_ready() {
  for attempt in {1..100}; do
    if curl --silent --fail --max-time 1 http://127.0.0.1:$server_port/health >/dev/null; then return 0; fi
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
    unloaded=false
    # launchd can briefly reject bootout while a freshly bootstrapped job is
    # spawning. Retry that same label; never remove files beneath a live job.
    for attempt in {1..50}; do
      if launchctl bootout "$domain/$label" 2>/dev/null; then unloaded=true; break; fi
      if ! launchctl print "$domain/$label" >/dev/null 2>&1; then unloaded=true; break; fi
      sleep 0.2
    done
    if [[ "$unloaded" != true ]]; then
      echo 'The server job could not be unloaded. Its files were preserved.' >&2
      return 1
    fi
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
    if [[ -n "$new_pid" && "$new_pid" != "$old_pid" ]] && curl --silent --fail --max-time 1 http://127.0.0.1:$server_port/health >/dev/null; then
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
