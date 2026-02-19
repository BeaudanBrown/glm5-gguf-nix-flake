#!/usr/bin/env bash
# connect.sh — Run from your LOCAL machine to find and test the HPC endpoint.
#
# Usage:
#   ./scripts/connect.sh                    # Uses default hostname
#   ./scripts/connect.sh hpc-glm5           # Specify hostname
#   SERVER=http://100.x.x.x:8080 ./scripts/connect.sh  # Direct URL
set -euo pipefail

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

TS_HOSTNAME="${1:-${TS_HOSTNAME:-hpc-glm5}}"
PORT="${PORT:-8080}"
SERVER="${SERVER:-http://$TS_HOSTNAME:$PORT}"

blue "=== Connecting to GLM-5 Server ==="
echo "  Target: $SERVER"
echo ""

# ── DNS resolution ──────────────────────────────────────────────────────
blue "1. DNS resolution..."
if command -v tailscale &>/dev/null; then
  TS_IP=$(tailscale ip -4 "$TS_HOSTNAME" 2>/dev/null) && {
    green "   Resolved $TS_HOSTNAME -> $TS_IP"
    # Use IP directly to avoid MagicDNS issues
    SERVER="http://$TS_IP:$PORT"
  } || {
    yellow "   Could not resolve via Tailscale. Trying direct..."
  }
else
  yellow "   Tailscale CLI not found. Using hostname directly."
fi

# ── Health check ────────────────────────────────────────────────────────
echo ""
blue "2. Health check..."
HEALTH=$(curl -sf --max-time 10 "$SERVER/health" 2>/dev/null) && {
  STATUS=$(echo "$HEALTH" | jq -r '.status // "unknown"' 2>/dev/null || echo "$HEALTH")
  green "   Server is up! Status: $STATUS"
} || {
  red "   FAILED: Server is not reachable at $SERVER"
  echo ""
  echo "   Troubleshooting:"
  echo "   - Is the SLURM job running?  (check with: squeue -u \$USER)"
  echo "   - Is Tailscale connected?    (check with: tailscale status)"
  echo "   - Is llama-server started?   (check HPC logs)"
  echo ""
  exit 1
}

# ── Model info ──────────────────────────────────────────────────────────
echo ""
blue "3. Available models..."
MODELS=$(curl -sf --max-time 10 "$SERVER/v1/models" 2>/dev/null) && {
  echo "$MODELS" | jq -r '.data[] | "   \(.id)"' 2>/dev/null || echo "   (could not parse response)"
} || echo "   (unavailable)"

# ── Quick inference test ────────────────────────────────────────────────
echo ""
blue "4. Quick inference test..."
RESPONSE=$(curl -sf --max-time 60 "$SERVER/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Say hello in exactly 5 words."}],
    "max_tokens": 50,
    "temperature": 0.7
  }' 2>/dev/null) && {
  CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "no content"' 2>/dev/null)
  TOKENS=$(echo "$RESPONSE" | jq -r '.usage.completion_tokens // "?"' 2>/dev/null)
  green "   Response: $CONTENT"
  echo "   Tokens: $TOKENS"
} || {
  yellow "   Inference test failed (server may still be loading model)"
}

# ── Print configuration snippets ────────────────────────────────────────
echo ""
echo ""
blue "=== Configuration Snippets ==="
echo ""

green "Loom (OpenAI-compatible provider):"
echo "  OPENAI_API_BASE=$SERVER/v1"
echo "  OPENAI_API_KEY=not-needed"
echo ""

green "Claude Code (custom provider):"
echo "  Add to your Claude Code settings:"
echo "  {"
echo "    \"apiProvider\": \"openai-compatible\","
echo "    \"openaiBaseUrl\": \"$SERVER/v1\","
echo "    \"openaiApiKey\": \"not-needed\","
echo "    \"openaiModelId\": \"$(echo "$MODELS" | jq -r '.data[0].id // "glm5"' 2>/dev/null)\""
echo "  }"
echo ""

green "OpenCode:"
echo "  Set in your opencode config:"
echo "  OPENAI_API_BASE=$SERVER/v1"
echo ""

green "curl:"
echo "  curl $SERVER/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100}'"
echo ""
