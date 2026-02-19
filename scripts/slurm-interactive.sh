#!/usr/bin/env bash
# slurm-interactive.sh — Launch an interactive SLURM job and start the
# full inference stack (Tailscale + llama-server).
#
# Usage:
#   ./scripts/slurm-interactive.sh              # 24h default
#   ./scripts/slurm-interactive.sh --time=4:00:00  # 4 hours
#
# This script is meant to be run from the HPC login node. It requests
# a GPU allocation via srun and then starts everything inside it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default SLURM parameters (override via env or args)
SLURM_TIME="${SLURM_TIME:-24:00:00}"
SLURM_GPUS="${SLURM_GPUS:-gpu:l40s:4}"
SLURM_CPUS="${SLURM_CPUS:-96}"
SLURM_MEM="${SLURM_MEM:-512G}"
SLURM_JOB_NAME="${SLURM_JOB_NAME:-glm5-server}"

# Pass through any extra srun arguments
EXTRA_ARGS=("$@")

echo "=== GLM-5 Interactive Session ==="
echo ""
echo "Requesting allocation:"
echo "  Job name: $SLURM_JOB_NAME"
echo "  GPUs:     $SLURM_GPUS"
echo "  CPUs:     $SLURM_CPUS"
echo "  Memory:   $SLURM_MEM"
echo "  Duration: $SLURM_TIME"
echo ""
echo "Starting interactive session..."
echo ""

# The heredoc script runs inside the allocated job.
# It enters the nix devShell, starts Tailscale, starts the server,
# then waits for the user to Ctrl-C.
exec srun \
  --job-name="$SLURM_JOB_NAME" \
  --time="$SLURM_TIME" \
  --gres="$SLURM_GPUS" \
  --cpus-per-task="$SLURM_CPUS" \
  --mem="$SLURM_MEM" \
  "${EXTRA_ARGS[@]}" \
  --pty bash -c "
    cd '$PROJECT_DIR'

    echo '=== Inside SLURM allocation ==='
    echo \"Node: \$(hostname)\"
    echo \"GPUs: \$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)\"
    echo ''

    # Source GPU passthrough for nixsa if needed
    if [ -f '$PROJECT_DIR/nixsa-gpu-setup.sh' ]; then
      source '$PROJECT_DIR/nixsa-gpu-setup.sh'
    fi

    # Load environment
    if [ -f '$PROJECT_DIR/.env' ]; then
      set -a; source '$PROJECT_DIR/.env'; set +a
    fi

    echo 'Entering nix devShell...'
    echo ''

    # Start inside nix develop
    # The exec replaces this shell so Ctrl-C works properly
    nix develop --command bash -c '
      # Start Tailscale
      echo \"\"
      glm5-tailscale-up

      echo \"\"
      echo \"=== Starting inference server ===\"
      echo \"Press Ctrl-C to stop.\"
      echo \"\"

      # Start server (runs in foreground, Ctrl-C stops it)
      glm5-serve
    '
  "
