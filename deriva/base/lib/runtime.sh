#!/bin/bash

main_pid=""
rsyslog_pid=""

log() {
  local tag="$1"; shift
  echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N%:z') [$tag] $*"
}

shutdown() {
  log "Received shutdown signal. Terminating processes..."

  if [ -n "$main_pid" ] && kill -0 "$main_pid" 2>/dev/null; then
    log "Stopping main process (PID $main_pid)"
    kill "$main_pid"
    wait "$main_pid" 2>/dev/null || true
  fi

  if [ -n "$rsyslog_pid" ] && kill -0 "$rsyslog_pid" 2>/dev/null; then
    log "Stopping rsyslogd (PID $rsyslog_pid)"
    kill "$rsyslog_pid"
    wait "$rsyslog_pid" 2>/dev/null || true
  fi

  log "Shutdown complete."
  exit 0
}

start_rsyslog() {
  if [ -f /run/rsyslogd.pid ]; then
    log "Removing stale rsyslog PID file"
    rm -f /run/rsyslogd.pid
  fi

  if command -v rsyslogd > /dev/null; then
    log "Starting rsyslogd"
    rsyslogd
    sleep 1
    if ! pidof rsyslogd > /dev/null; then
      log "rsyslogd failed to start. Exiting container."
      exit 1
    fi
    rsyslog_pid=$(pidof rsyslogd)
  else
    log "rsyslogd not found; skipping syslog setup"
  fi
}

start_main_process() {
  if [ $# -eq 0 ]; then
    log "No command specified; exiting"
    exit 1
  fi

  log "Starting main process: $*"
  "$@" &
  main_pid=$!
}

monitor_loop() {
  while true; do
    if [ -n "$rsyslog_pid" ] && ! kill -0 "$rsyslog_pid" 2>/dev/null; then
      log "rsyslogd has terminated unexpectedly. Shutting down."
      shutdown
    fi

    if ! kill -0 "$main_pid" 2>/dev/null; then
      log "Main process has exited. Shutting down."
      shutdown
    fi

    sleep 2
  done
}

# Install signal trap
trap shutdown SIGINT SIGTERM
