#!/usr/bin/env bash
# slurm-interactive.sh — Request an interactive SLURM allocation and start
# the full inference stack (Tailscale + llama-server) inside it.
#
# Usage (from the project root on the HPC login node):
#   ./scripts/slurm-interactive.sh              # 24 h default
#   ./scripts/slurm-interactive.sh --time=4:00:00
#
# Unlike sbatch, this holds the terminal — Ctrl-C stops the server and
# releases the allocation cleanly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default SLURM parameters (override via environment or pass extra srun args)
SLURM_TIME="${SLURM_TIME:-24:00:00}"
SLURM_GPUS="${SLURM_GPUS:-gpu:l40s:4}"
SLURM_CPUS="${SLURM_CPUS:-96}"
SLURM_MEM="${SLURM_MEM:-512G}"
SLURM_JOB_NAME="${SLURM_JOB_NAME:-glm5-server}"

EXTRA_SRUN_ARGS=("$@")

echo "=== GLM-5 Interactive Session ==="
echo ""
echo "Requesting allocation:"
echo "  Job name: $SLURM_JOB_NAME"
echo "  GPUs:     $SLURM_GPUS"
echo "  CPUs:     $SLURM_CPUS"
echo "  Memory:   $SLURM_MEM"
echo "  Duration: $SLURM_TIME"
echo ""
echo "Waiting for allocation (this may take a while in the queue)..."
echo ""

# Export everything the inner script needs so it survives the srun boundary.
export PROJECT_DIR
export TS_STATE_DIR="${TS_STATE_DIR:-$PROJECT_DIR/.tailscale-state}"
export TS_SOCKET="${TS_SOCKET:-$TS_STATE_DIR/tailscaled.sock}"
export TS_HOSTNAME="${TS_HOSTNAME:-hpc-glm5}"
export PORT="${PORT:-8080}"

# Load .env on the login node so the auth key etc. are in the environment
# that srun inherits (srun propagates the environment by default).
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

exec srun \
  --job-name="$SLURM_JOB_NAME" \
  --time="$SLURM_TIME" \
  --gres="$SLURM_GPUS" \
  --cpus-per-task="$SLURM_CPUS" \
  --mem="$SLURM_MEM" \
  "${EXTRA_SRUN_ARGS[@]}" \
  --pty bash -c "
    set -euo pipefail
    cd '$PROJECT_DIR'

    echo '=== Inside SLURM allocation ==='
    echo \"Node: \$(hostname)\"
    echo \"GPUs: \$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l) detected\"
    echo ''

    # Source GPU passthrough for nixsa
    if [ -f '$PROJECT_DIR/nixsa-gpu-setup.sh' ]; then
      source '$PROJECT_DIR/nixsa-gpu-setup.sh'
    fi

    echo 'Entering nix devShell...'
    echo ''

    nix develop --command bash -c '
      set -euo pipefail

      glm5-tailscale-up

      TS_IP=\$(tailscale --socket=\"\$TS_SOCKET\" ip -4 2>/dev/null || echo unknown)
      echo \"\"
      echo \"API endpoint: http://\$TS_IP:\$PORT/v1\"
      echo \"From your local machine: bash scripts/connect.sh\"
      echo \"\"

      echo \"=== Starting inference server (Ctrl-C to stop) ===\"
      echo \"\"
      glm5-serve
    '
  "
