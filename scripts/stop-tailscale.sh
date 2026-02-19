#!/usr/bin/env bash
# stop-tailscale.sh — Cleanly shut down the userspace Tailscale daemon.
set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
TS_STATE_DIR="${TS_STATE_DIR:-$PROJECT_DIR/.tailscale-state}"
TS_SOCKET="${TS_SOCKET:-$TS_STATE_DIR/tailscaled.sock}"
PID_FILE="$TS_STATE_DIR/tailscaled.pid"

blue "=== Stopping Tailscale ==="

# Try graceful logout first
if [ -S "$TS_SOCKET" ]; then
  yellow "Logging out of tailnet..."
  tailscale --socket="$TS_SOCKET" logout 2>/dev/null || true
fi

# Kill the daemon
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    yellow "Stopping tailscaled (PID: $PID)..."
    kill "$PID"

    # Wait for clean exit
    for i in $(seq 1 10); do
      if ! kill -0 "$PID" 2>/dev/null; then
        break
      fi
      sleep 1
    done

    # Force kill if still alive
    if kill -0 "$PID" 2>/dev/null; then
      yellow "Force-killing tailscaled..."
      kill -9 "$PID" 2>/dev/null || true
    fi
  fi
  rm -f "$PID_FILE"
fi

# Also kill any orphaned tailscaled processes we started
pkill -f "tailscaled.*--socket=$TS_SOCKET" 2>/dev/null || true

# Clean up socket
rm -f "$TS_SOCKET"

green "Tailscale stopped."
echo ""
echo "Note: State is preserved in $TS_STATE_DIR"
echo "      Next 'tailscale up' will reconnect quickly."
