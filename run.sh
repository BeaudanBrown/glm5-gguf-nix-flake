#!/usr/bin/env bash
# run.sh — Quick CLI inference using llama-cli (non-server mode).
#
# Expects to be run from inside `nix develop` where MODELS_DIR is set.
# Falls back to ./cache relative to the script location if MODELS_DIR is unset.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${MODELS_DIR:-$SCRIPT_DIR/cache}"

MODEL_PATH="$MODELS_DIR/models--unsloth--GLM-5-GGUF/snapshots/ff5c55c3470d73e038cc33301d66f197b679660e/UD-Q4_K_XL/GLM-5-UD-Q4_K_XL-00001-of-00010.gguf"

if [ ! -f "$MODEL_PATH" ]; then
  echo "ERROR: Model not found at: $MODEL_PATH" >&2
  echo "  MODELS_DIR is set to: $MODELS_DIR" >&2
  echo "  Download the model first (e.g. via huggingface-cli download)." >&2
  exit 1
fi

exec llama-cli -m "$MODEL_PATH" \
        --fit on \
        --ctx-size 16384 \
        --batch-size 512 \
        --ubatch-size 128 \
        --flash-attn auto \
        --threads 95
