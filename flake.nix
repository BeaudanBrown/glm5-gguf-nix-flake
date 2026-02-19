{
  description = "GLM-5 GGUF inference server with Tailscale mesh networking for HPC";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
        };

        # nixpkgs llama-cpp b7898 (2026-02-01) predates GLM-5 DSA arch support,
        # which landed upstream on 2026-02-14 (commit 752584d, PR #19460).
        # Pin to release b8087 (2026-02-18) which is the tagged release that
        # includes it. Version must be a plain integer — nixpkgs uses it
        # verbatim as LLAMA_BUILD_NUMBER in generated C++ code.
        llamaSrc = pkgs.fetchFromGitHub {
          owner = "ggml-org";
          repo  = "llama.cpp";
          rev   = "b8087";
          hash  = "sha256-M5J6RfOCYDn65fw+2mogvEiyc2UVA3STH86U8qInrQk=";
        };

        llama = (pkgs.llama-cpp.override {
          cudaSupport = true;
        }).overrideAttrs (_old: {
          src     = llamaSrc;
          version = "8087";
        });

        py = pkgs.python3.withPackages (ps: [
          ps.huggingface-hub
        ]);

        # -----------------------------------------------------------------
        # Wrapper scripts (installed as packages so they work with nix run)
        # -----------------------------------------------------------------

        startServerScript = pkgs.writeShellScriptBin "glm5-serve" (builtins.readFile ./scripts/start-server.sh);
        startTailscaleScript = pkgs.writeShellScriptBin "glm5-tailscale-up" (builtins.readFile ./scripts/start-tailscale.sh);
        stopTailscaleScript = pkgs.writeShellScriptBin "glm5-tailscale-down" (builtins.readFile ./scripts/stop-tailscale.sh);
        healthCheckScript = pkgs.writeShellScriptBin "glm5-health" (builtins.readFile ./scripts/health-check.sh);

        # All runtime dependencies that scripts need on PATH
        runtimeDeps = [
          llama
          pkgs.tailscale
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.gawk
          pkgs.procps     # pgrep / pkill
        ];

        # Wrap scripts with runtime deps on PATH
        wrapScript = drv: pkgs.symlinkJoin {
          name = drv.name;
          paths = [ drv ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            for f in $out/bin/*; do
              wrapProgram "$f" --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
            done
          '';
        };

        serve       = wrapScript startServerScript;
        tailscaleUp = wrapScript startTailscaleScript;
        tailscaleDown = wrapScript stopTailscaleScript;
        healthCheck = wrapScript healthCheckScript;

      in
      {
        packages = {
          default     = llama;
          llama-cpp   = llama;
          serve       = serve;
          tailscale-up   = tailscaleUp;
          tailscale-down = tailscaleDown;
          health-check   = healthCheck;
        };

        apps = {
          # nix run .#serve
          serve = {
            type = "app";
            program = "${serve}/bin/glm5-serve";
          };
          # nix run .#tailscale-up
          tailscale-up = {
            type = "app";
            program = "${tailscaleUp}/bin/glm5-tailscale-up";
          };
          # nix run .#tailscale-down
          tailscale-down = {
            type = "app";
            program = "${tailscaleDown}/bin/glm5-tailscale-down";
          };
          # nix run .#health
          health = {
            type = "app";
            program = "${healthCheck}/bin/glm5-health";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = runtimeDeps ++ [
            py
            serve
            tailscaleUp
            tailscaleDown
            healthCheck
          ];

          shellHook = ''
            export PROJECT_DIR="$PWD"
            export MODELS_DIR="$PROJECT_DIR/.models"

            export HF_HOME="$MODELS_DIR/hf"
            export HF_HUB_CACHE="$HF_HOME/hub"
            export HUGGINGFACE_HUB_CACHE="$HF_HUB_CACHE"
            export TRANSFORMERS_CACHE="$HF_HOME/transformers"

            mkdir -p "$HF_HUB_CACHE" "$TRANSFORMERS_CACHE" "$MODELS_DIR/gguf"

            # Host NVIDIA driver libraries (non-NixOS / HPC).
            #
            # On this HPC the NVIDIA .so files live in /lib64 alongside the
            # system glibc/libstdc++.  Adding all of /lib64 to LD_LIBRARY_PATH
            # shadows the Nix-provided C library and causes
            #   "GLIBC_2.38 not found" errors.
            #
            # Fix: create a private directory containing symlinks to *only* the
            # NVIDIA/CUDA driver libraries, and put that on LD_LIBRARY_PATH.
            _nv_stubs="$PROJECT_DIR/.nv-driver-libs"
            rm -rf "$_nv_stubs"
            mkdir -p "$_nv_stubs"
            _found=0
            for _src in /lib64 /usr/lib64 /usr/lib/x86_64-linux-gnu; do
              for _so in \
                "$_src"/libcuda.so* \
                "$_src"/libcudadebugger.so* \
                "$_src"/libcuda_wrapper.so* \
                "$_src"/libnvidia*.so* \
                "$_src"/libnvcuvid.so* \
                "$_src"/libvdpau_nvidia.so* ; do
                [ -e "$_so" ] && ln -sf "$_so" "$_nv_stubs/" && _found=1
              done
            done
            if [ "$_found" -eq 1 ]; then
              export LD_LIBRARY_PATH="''${_nv_stubs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            fi
            unset _nv_stubs _found _src _so

            # Tailscale state directory (persists across SLURM jobs)
            export TS_STATE_DIR="$PROJECT_DIR/.tailscale-state"
            export TS_SOCKET="$TS_STATE_DIR/tailscaled.sock"
            mkdir -p "$TS_STATE_DIR"

            # Load secrets from .env if present
            if [ -f "$PROJECT_DIR/.env" ]; then
              set -a
              source "$PROJECT_DIR/.env"
              set +a
            fi

            echo "=== GLM-5 Inference Server ==="
            echo ""
            echo "Model dir : $MODELS_DIR"
            echo "HF cache  : $HF_HUB_CACHE"
            echo "TS state  : $TS_STATE_DIR"
            echo ""

            if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
              echo "GPUs detected:"
              nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null | while read -r line; do
                echo "  $line"
              done
              GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)

              CPU_CORES=$(nproc 2>/dev/null || echo 8)
              T_GEN=$(( CPU_CORES / 2 ))
              T_BATCH=$CPU_CORES

              echo ""
              echo "Recommended threading: -t $T_GEN -tb $T_BATCH"
            else
              echo "WARNING: nvidia-smi not available."
              echo "Make sure NIXSA_BWRAP_ARGS is set (see nixsa-gpu-setup.sh)."
            fi

            echo ""
            echo "Commands:"
            echo "  glm5-tailscale-up   Start Tailscale (userspace, no root)"
            echo "  glm5-serve          Start llama-server (OpenAI-compatible)"
            echo "  glm5-health         Check server health + metrics"
            echo "  glm5-tailscale-down Stop Tailscale"
            echo ""
          '';
        };
      });
}
