{
  description = "Run GLM-5 GGUF with llama.cpp (CUDA) using local ./.models";

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
      in
      {
        packages = {
          default = llama;
          llama-cpp = llama;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            llama
            py
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

            echo "Model dir: $MODELS_DIR"
            echo "HF cache : $HF_HUB_CACHE"
            echo ""
            if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
              echo "GPUs detected:"
              nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null | while read -r line; do
                echo "  $line"
              done
              GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
              SPLIT=$(seq 1 "$GPU_COUNT" | awk 'BEGIN{ORS=","} {print 1}' | sed 's/,$//')

              # CPU threading: use half physical cores for generation (memory-bandwidth
              # bound), full cores for prompt processing (compute bound).
              CPU_CORES=$(nproc 2>/dev/null || echo 8)
              T_GEN=$(( CPU_CORES / 2 ))
              T_BATCH=$CPU_CORES

            else
              echo "WARNING: nvidia-smi not available. NVIDIA devices may not be bound into the sandbox."
              echo "Make sure NIXSA_BWRAP_ARGS is set (see nixsa-gpu-setup.sh)."
            fi
          '';
        };
      });
}
