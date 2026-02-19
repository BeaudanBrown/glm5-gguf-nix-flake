#!/usr/bin/env bash
# start-server.sh — Start llama-server as an OpenAI-compatible endpoint.
#
# This script auto-detects GPUs, calculates optimal threading, and starts
# llama-server with sensible defaults. All settings can be overridden via
# environment variables.
#
# Environment variables:
#   MODEL_PATH     Path to GGUF file (auto-detected from .models/ if unset)
#   HOST           Bind address (default: 0.0.0.0)
#   PORT           Listen port (default: 8080)
#   CTX_SIZE       Context window per slot (default: 16384)
#   PARALLEL       Number of parallel slots (default: 2)
#   BATCH_SIZE     Batch size (default: 2048)
#   UBATCH_SIZE    Micro-batch size (default: 512)
#   THREADS        Generation threads (default: half of nproc)
#   THREADS_BATCH  Batch processing threads (default: nproc)
#   EXTRA_ARGS     Additional llama-server arguments
set -euo pipefail

# ── Colour helpers ──────────────────────────────────────────────────────
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

# ── Model discovery ─────────────────────────────────────────────────────
find_model() {
  # If MODEL_PATH is set and valid, use it
  if [ -n "${MODEL_PATH:-}" ] && [ -f "$MODEL_PATH" ]; then
    echo "$MODEL_PATH"
    return
  fi

  # Search common locations for GGUF files
  local search_dirs=(
    "${MODELS_DIR:-$PWD/.models}"
    "$PWD/cache"
    "$PWD"
  )

  for dir in "${search_dirs[@]}"; do
    if [ -d "$dir" ]; then
      # Find the first shard of any multi-part GGUF (prefer GLM-5)
      local found
      found=$(find "$dir" -name '*GLM-5*-00001-of-*.gguf' -type f 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        echo "$found"
        return
      fi
      # Fall back to any GGUF
      found=$(find "$dir" -name '*.gguf' -type f 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        echo "$found"
        return
      fi
    fi
  done

  return 1
}

# ── GPU detection ───────────────────────────────────────────────────────
detect_gpus() {
  if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null 2>&1; then
    echo "0"
    return
  fi
  nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l
}

# ── Main ────────────────────────────────────────────────────────────────
blue "=== GLM-5 Inference Server ==="
echo ""

# Find model
MODEL_PATH=$(find_model) || {
  red "ERROR: No GGUF model found."
  echo "Set MODEL_PATH or download a model:"
  echo "  huggingface-cli download unsloth/GLM-5-GGUF --local-dir ./.models/gguf"
  exit 1
}
green "Model: $MODEL_PATH"

# Detect GPUs
GPU_COUNT=$(detect_gpus)
if [ "$GPU_COUNT" -eq 0 ]; then
  yellow "WARNING: No GPUs detected. Running on CPU only."
else
  green "GPUs: $GPU_COUNT"
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null | while read -r line; do
    echo "  $line"
  done
fi

# Calculate threading
CPU_CORES=$(nproc 2>/dev/null || echo 8)
THREADS="${THREADS:-$(( CPU_CORES / 2 ))}"
THREADS_BATCH="${THREADS_BATCH:-$CPU_CORES}"

# Build tensor split string (equal split across all GPUs)
TENSOR_SPLIT=""
if [ "$GPU_COUNT" -gt 1 ]; then
  TENSOR_SPLIT=$(seq 1 "$GPU_COUNT" | awk 'BEGIN{ORS=","} {print 1}' | sed 's/,$//')
fi

# Server configuration
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
CTX_SIZE="${CTX_SIZE:-16384}"
PARALLEL="${PARALLEL:-2}"
BATCH_SIZE="${BATCH_SIZE:-2048}"
UBATCH_SIZE="${UBATCH_SIZE:-512}"

echo ""
blue "Configuration:"
echo "  Host:          $HOST:$PORT"
echo "  Context/slot:  $CTX_SIZE tokens"
echo "  Parallel:      $PARALLEL slots"
echo "  Batch:         $BATCH_SIZE / $UBATCH_SIZE"
echo "  Threads:       $THREADS gen / $THREADS_BATCH batch"
[ -n "$TENSOR_SPLIT" ] && echo "  Tensor split:  $TENSOR_SPLIT"
echo ""

# Build command
CMD=(
  llama-server
  -m "$MODEL_PATH"
  --host "$HOST"
  --port "$PORT"
  --ctx-size "$CTX_SIZE"
  --parallel "$PARALLEL"
  --batch-size "$BATCH_SIZE"
  --ubatch-size "$UBATCH_SIZE"
  --threads "$THREADS"
  --threads-batch "$THREADS_BATCH"
  --flash-attn
  --metrics
  --fit on
)

# GPU-specific flags
if [ "$GPU_COUNT" -gt 0 ]; then
  CMD+=(--n-gpu-layers 999)
  if [ -n "$TENSOR_SPLIT" ]; then
    CMD+=(--tensor-split "$TENSOR_SPLIT")
  fi
fi

# Append any extra args
if [ -n "${EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  CMD+=($EXTRA_ARGS)
fi

green "Starting llama-server..."
echo "  ${CMD[*]}"
echo ""
yellow "OpenAI-compatible API will be available at:"
echo "  http://$HOST:$PORT/v1"
echo ""
yellow "Endpoints:"
echo "  POST /v1/chat/completions   Chat completions"
echo "  POST /v1/completions        Text completions"
echo "  GET  /v1/models             List models"
echo "  GET  /health                Health check"
echo "  GET  /metrics               Prometheus metrics"
echo ""

exec "${CMD[@]}"
