# GLM-5 GGUF on Nix (CUDA)

This flake provides **llama.cpp with CUDA** plus a dev shell that pins Hugging Face caches to `./.models`.

## Requirements

* Nix with flakes enabled
* NVIDIA driver installed on the host (A100s in your case)

## Enter the shell

```bash
nix develop
```

## Download model files into `./.models`

```bash
hf download unsloth/GLM-5-GGUF --cache-dir ./.models/hf/hub
```

Copy or symlink the GGUF you want to run into `./.models/gguf/`.

## Run (CLI)

```bash
llama-cli -m ./.models/gguf/<file>.gguf -ngl 99 -c 8192 -p "Hello"
```

## Run on 2 GPUs

```bash
llama-cli -m ./.models/gguf/<file>.gguf -ngl 99 --tensor-split 1,1 -c 8192 -p "Hello"
```

## Run as a server

```bash
llama-server -m ./.models/gguf/<file>.gguf -ngl 99 --tensor-split 1,1 -c 8192 --port 8000
```
