# GLM-5 Inference Server for HPC

Run GLM-5 as an OpenAI-compatible API on shared HPC infrastructure (no root
required), exposed to your private Tailscale network. Designed for use with
[loom](https://github.com/ghuntley/loom), Claude Code, OpenCode, or any
OpenAI-compatible client.

## Architecture

```
  Local Machine                Your NixOS Server          HPC SLURM Node
  ┌──────────────┐            ┌──────────────┐           ┌──────────────────┐
  │ Claude Code  │            │ loom-server  │           │ llama-server     │
  │ OpenCode     │───────────▶│ (weavers,    │──────────▶│ :8080            │
  │ loom-cli     │  Tailscale │  tools, git) │ Tailscale │ 4x L40S GPUs     │
  │ curl         │            │              │           │ OpenAI-compat API│
  └──────────────┘            └──────────────┘           └──────────────────┘
       All connected via Tailscale mesh — no public internet exposure
```

## Requirements

- Nix with flakes (installed via [nixsa](https://github.com/numtide/nixsa) on HPC)
- NVIDIA GPUs on the HPC node
- Tailscale account with an auth key

## Quick Start

### 1. Configure secrets

```bash
cp .env.example .env
# Edit .env: set TS_AUTHKEY and optionally MODEL_PATH
```

### 2. Interactive SLURM session (recommended)

```bash
# From the HPC login node:
./scripts/slurm-interactive.sh

# Or manually:
srun --gres=gpu:l40s:4 --cpus-per-task=96 --mem=512G --time=24:00:00 --pty bash
nix develop
glm5-tailscale-up
glm5-serve
```

### 3. Batch SLURM job

```bash
mkdir -p logs
sbatch scripts/slurm-batch.sh
# Monitor: tail -f logs/glm5-<jobid>.out
```

### 4. Connect from your local machine

```bash
# Check the server is reachable:
./scripts/connect.sh

# Or manually:
curl http://hpc-glm5:8080/health
curl http://hpc-glm5:8080/v1/models
```

## Commands

All commands are available as `nix run` apps or on `$PATH` inside `nix develop`:

| Command | Description |
|---|---|
| `glm5-serve` / `nix run .#serve` | Start llama-server with auto-detected GPU config |
| `glm5-tailscale-up` / `nix run .#tailscale-up` | Start Tailscale in userspace mode (no root) |
| `glm5-tailscale-down` / `nix run .#tailscale-down` | Stop Tailscale cleanly |
| `glm5-health` / `nix run .#health` | Health check + metrics display |

## Configuration

All configuration is via environment variables (see `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `TS_AUTHKEY` | (required) | Tailscale auth key |
| `TS_HOSTNAME` | `hpc-glm5` | Name on your tailnet |
| `MODEL_PATH` | (auto-detect) | Path to GGUF model file |
| `PORT` | `8080` | llama-server listen port |
| `CTX_SIZE` | `65536` | Context window per slot |
| `PARALLEL` | `2` | Number of parallel inference slots |
| `BATCH_SIZE` | `2048` | Batch size for prompt processing |
| `UBATCH_SIZE` | `512` | Micro-batch size |
| `CACHE_TYPE_K` | `q8_0` | KV cache quantisation for keys |
| `CACHE_TYPE_V` | `q8_0` | KV cache quantisation for values |
| `THREADS` | `nproc/2` | CPU threads for generation |
| `THREADS_BATCH` | `nproc` | CPU threads for batch processing |

## Using with Loom

On your NixOS server where loom-server runs, configure the OpenAI-compatible
backend to point at the HPC endpoint:

```bash
OPENAI_API_BASE=http://hpc-glm5:8080/v1
OPENAI_API_KEY=not-needed
```

See `config/loom-openai.env` for a complete example.

## Using with Claude Code

Add a custom provider in your Claude Code settings:

```json
{
  "apiProvider": "openai-compatible",
  "openaiBaseUrl": "http://hpc-glm5:8080/v1",
  "openaiApiKey": "not-needed"
}
```

## Parallel Slots & Subagents

With `--parallel 2` (the default), llama-server maintains two independent
inference slots, each with a 65K token context window. This enables:

- **Slot 0**: Main agent conversation
- **Slot 1**: Subagent tasks (code search, summarisation)

When one slot is idle (waiting for tool results), the other gets full GPU
throughput. This is nearly free at 5-10 tps since the slots alternate rather
than competing.

GLM-5 uses MLA (Multi-Latent Attention) with a compressed KV cache (~78 KB
per token), so 2 slots at 65K context costs only ~10 GB total — a tiny
fraction of the available VRAM.

To increase parallelism: `PARALLEL=4 glm5-serve`

## Downloading the Model

Q4_K_XL is the recommended quantisation for 4x L40S (180 GB VRAM).  It puts
~42% of the model on GPU and gives ~2x inference speed over Q8_K_XL with
negligible quality loss on this 744B MoE architecture.

```bash
nix develop
huggingface-cli download unsloth/GLM-5-GGUF \
  --include "UD-Q4_K_XL/*" \
  --local-dir ./.models/gguf
```

Other quantisations (adjust `--include` pattern):

| Quant | Size | GPU offload (4x L40S) | Notes |
|---|---|---|---|
| `UD-Q4_K_XL` | 431 GB | ~42% | **Recommended** — best speed/quality |
| `UD-Q5_K_XL` | 536 GB | ~34% | Slightly better quality, slower |
| `UD-Q8_K_XL` | 869 GB | ~21% | Negligible quality gain, ~2x slower |

## Tailscale Userspace Mode

This flake runs Tailscale in **userspace networking mode** (`--tun=userspace`),
which means:

- No root access required
- No kernel modules needed
- No `/dev/net/tun` device needed
- Works inside SLURM job allocations
- State persists across jobs in `.tailscale-state/`

Inbound TCP connections (from other tailnet devices to llama-server) work
normally. For outbound connections from the HPC node, Tailscale provides a
SOCKS5 proxy.
