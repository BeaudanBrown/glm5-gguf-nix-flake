#!/usr/bin/env bash
# start-tailscale.sh — Start Tailscale in userspace-networking mode (no root required).
#
# This is designed for HPC environments where you don't have root access and
# /dev/net/tun is unavailable or the tun kernel module cannot be loaded.
#
# Uses --tun=userspace-networking which runs a full SOCKS5/HTTP proxy inside
# the tailscaled process instead of creating a kernel TUN device.  No
# iptables, no modprobe, no /dev/net/tun required.
#
# Note: In userspace-networking mode, only outbound connections from *this*
# node work automatically.  Inbound connections (e.g. other tailnet peers
# reaching the llama-server port) require explicitly binding the server to
# the Tailscale IP rather than 0.0.0.0, or using `tailscale serve`.
#
# Environment variables:
#   TS_AUTHKEY     Tailscale auth key (required on first run)
#   TS_HOSTNAME    Machine name on tailnet (default: hpc-glm5)
#   TS_STATE_DIR   Directory for persistent state (default: ./.tailscale-state)
#   TS_SOCKET      Path to tailscaled socket (default: $TS_STATE_DIR/tailscaled.sock)
#   TS_EXTRA_ARGS  Additional arguments for `tailscale up`
set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
TS_STATE_DIR="${TS_STATE_DIR:-$PROJECT_DIR/.tailscale-state}"
TS_SOCKET="${TS_SOCKET:-$TS_STATE_DIR/tailscaled.sock}"
TS_HOSTNAME="${TS_HOSTNAME:-hpc-glm5}"
TS_LOG="$TS_STATE_DIR/tailscaled.log"

mkdir -p "$TS_STATE_DIR"

blue "=== Tailscale Userspace Setup ==="
echo ""

# Check if tailscaled is already running
if [ -S "$TS_SOCKET" ] && tailscale --socket="$TS_SOCKET" status &>/dev/null 2>&1; then
  green "Tailscale is already running."
  tailscale --socket="$TS_SOCKET" status
  echo ""
  TS_IP=$(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null || echo "unknown")
  green "Tailscale IP: $TS_IP"
  exit 0
fi

# Clean up stale socket if daemon isn't running
if [ -S "$TS_SOCKET" ]; then
  yellow "Removing stale socket..."
  rm -f "$TS_SOCKET"
fi

# Start tailscaled in userspace mode
blue "Starting tailscaled (userspace mode)..."
echo "  State: $TS_STATE_DIR"
echo "  Socket: $TS_SOCKET"
echo "  Log: $TS_LOG"
echo ""

tailscaled \
  --tun=userspace-networking \
  --socket="$TS_SOCKET" \
  --state="$TS_STATE_DIR/tailscaled.state" \
  --statedir="$TS_STATE_DIR" \
  > "$TS_LOG" 2>&1 &

TAILSCALED_PID=$!
echo "$TAILSCALED_PID" > "$TS_STATE_DIR/tailscaled.pid"

# Wait for the socket to appear
echo -n "Waiting for tailscaled to start"
for i in $(seq 1 30); do
  if [ -S "$TS_SOCKET" ]; then
    echo ""
    green "tailscaled started (PID: $TAILSCALED_PID)"
    break
  fi
  echo -n "."
  sleep 1
done

if [ ! -S "$TS_SOCKET" ]; then
  echo ""
  red "ERROR: tailscaled failed to start within 30s."
  echo "Check logs: $TS_LOG"
  cat "$TS_LOG"
  exit 1
fi

# Bring the interface up
blue "Running tailscale up..."

UP_CMD=(
  tailscale --socket="$TS_SOCKET" up
  --hostname="$TS_HOSTNAME"
)

if [ -n "${TS_AUTHKEY:-}" ]; then
  UP_CMD+=(--authkey="$TS_AUTHKEY")
else
  yellow "No TS_AUTHKEY set. If this is the first run, you may need to"
  yellow "authenticate interactively or set TS_AUTHKEY in .env"
fi

if [ -n "${TS_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  UP_CMD+=($TS_EXTRA_ARGS)
fi

"${UP_CMD[@]}"

# Wait for connection and display info
sleep 2

echo ""
if tailscale --socket="$TS_SOCKET" status &>/dev/null; then
  green "Tailscale is connected!"
  echo ""
  tailscale --socket="$TS_SOCKET" status
  echo ""

  TS_IP=$(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null || echo "unknown")
  green "Tailscale IPv4: $TS_IP"

  TS_IP6=$(tailscale --socket="$TS_SOCKET" ip -6 2>/dev/null || echo "unknown")
  echo "Tailscale IPv6: $TS_IP6"

  echo ""
  green "This node is reachable as:"
  echo "  http://$TS_HOSTNAME:8080/v1    (via MagicDNS)"
  echo "  http://$TS_IP:8080/v1          (via IPv4)"
  echo ""
  yellow "Now start the server:  glm5-serve"
else
  red "ERROR: Tailscale failed to connect."
  echo "Check logs: $TS_LOG"
  tailscale --socket="$TS_SOCKET" status 2>&1 || true
  exit 1
fi
