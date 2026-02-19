#!/usr/bin/env bash
# health-check.sh — Check llama-server health and display metrics.
#
# Environment variables:
#   SERVER_URL   Base URL of llama-server (default: http://localhost:8080)
set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

SERVER_URL="${SERVER_URL:-http://localhost:8080}"

blue "=== GLM-5 Server Health Check ==="
echo "  Server: $SERVER_URL"
echo ""

# ── Health endpoint ─────────────────────────────────────────────────────
echo -n "Health: "
HEALTH=$(curl -sf --max-time 5 "$SERVER_URL/health" 2>/dev/null) && {
  STATUS=$(echo "$HEALTH" | jq -r '.status // "unknown"' 2>/dev/null || echo "$HEALTH")
  if [ "$STATUS" = "ok" ] || [ "$STATUS" = "no slot available" ]; then
    green "$STATUS"
  else
    yellow "$STATUS"
  fi
} || {
  red "UNREACHABLE"
  echo ""
  echo "Is llama-server running? Start it with: glm5-serve"
  exit 1
}

# ── Model info ──────────────────────────────────────────────────────────
echo ""
blue "Models:"
MODELS=$(curl -sf --max-time 5 "$SERVER_URL/v1/models" 2>/dev/null) && {
  echo "$MODELS" | jq -r '.data[] | "  \(.id)  (owned by: \(.owned_by))"' 2>/dev/null || echo "  (could not parse)"
} || echo "  (unavailable)"

# ── Slots info ──────────────────────────────────────────────────────────
echo ""
blue "Slots:"
SLOTS=$(curl -sf --max-time 5 "$SERVER_URL/slots" 2>/dev/null) && {
  echo "$SLOTS" | jq -r '.[] | "  Slot \(.id): state=\(.state) prompt_tokens=\(.prompt_tokens // 0) predicted_tokens=\(.predicted_tokens // 0)"' 2>/dev/null || echo "  (could not parse)"
} || echo "  (unavailable — may need --slots-endpoint-disable to be off)"

# ── Metrics (Prometheus format) ─────────────────────────────────────────
echo ""
blue "Performance metrics:"
METRICS=$(curl -sf --max-time 5 "$SERVER_URL/metrics" 2>/dev/null) && {
  # Extract key metrics
  extract() {
    echo "$METRICS" | grep "^$1 " | awk '{print $2}' 2>/dev/null
  }

  PP_TOKENS=$(extract "llamacpp:prompt_tokens_total")
  GEN_TOKENS=$(extract "llamacpp:tokens_predicted_total")
  PP_SEC=$(extract "llamacpp:prompt_tokens_seconds")
  GEN_SEC=$(extract "llamacpp:tokens_predicted_seconds")
  KV_USED=$(extract "llamacpp:kv_cache_usage_ratio")
  REQUESTS=$(extract "llamacpp:requests_processing")
  QUEUE=$(extract "llamacpp:requests_pending")

  [ -n "$PP_TOKENS" ]  && echo "  Prompt tokens processed: $PP_TOKENS"
  [ -n "$GEN_TOKENS" ] && echo "  Tokens generated:        $GEN_TOKENS"
  [ -n "$PP_SEC" ]     && echo "  Prompt throughput:       ${PP_SEC} tok/s"
  [ -n "$GEN_SEC" ]    && echo "  Generation throughput:   ${GEN_SEC} tok/s"
  [ -n "$KV_USED" ]    && printf "  KV cache usage:          %.1f%%\n" "$(echo "$KV_USED * 100" | bc -l 2>/dev/null || echo "$KV_USED")"
  [ -n "$REQUESTS" ]   && echo "  Active requests:         $REQUESTS"
  [ -n "$QUEUE" ]      && echo "  Queued requests:         $QUEUE"

  if [ -z "$PP_TOKENS" ] && [ -z "$GEN_TOKENS" ]; then
    echo "  (no inference activity yet)"
  fi
} || echo "  (unavailable — server may not have --metrics enabled)"

# ── Tailscale connectivity ──────────────────────────────────────────────
echo ""
TS_STATE_DIR="${TS_STATE_DIR:-${PROJECT_DIR:-$PWD}/.tailscale-state}"
TS_SOCKET="${TS_SOCKET:-$TS_STATE_DIR/tailscaled.sock}"

blue "Tailscale:"
if [ -S "$TS_SOCKET" ] && tailscale --socket="$TS_SOCKET" status &>/dev/null 2>&1; then
  TS_IP=$(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null || echo "unknown")
  TS_NAME=$(tailscale --socket="$TS_SOCKET" status --json 2>/dev/null | jq -r '.Self.DNSName // "unknown"' | sed 's/\.$//')
  green "  Connected as: $TS_NAME ($TS_IP)"
  echo ""
  green "Remote access:"
  echo "  http://$TS_IP:${PORT:-8080}/v1"
  echo "  http://$TS_NAME:${PORT:-8080}/v1"
else
  yellow "  Not connected (start with: glm5-tailscale-up)"
fi

echo ""
