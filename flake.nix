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

        llama = pkgs.llama-cpp.override {
          cudaSupport = true;
        };

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
            set -eu

            export PROJECT_DIR="$PWD"
            export MODELS_DIR="$PROJECT_DIR/.models"

            # Hugging Face cache to a project-local directory.
            export HF_HOME="$MODELS_DIR/hf"
            export HF_HUB_CACHE="$HF_HOME/hub"
            export HUGGINGFACE_HUB_CACHE="$HF_HUB_CACHE"
            export TRANSFORMERS_CACHE="$HF_HOME/transformers"

            mkdir -p "$HF_HUB_CACHE" "$TRANSFORMERS_CACHE" "$MODELS_DIR/gguf"

            echo "Model dir: $MODELS_DIR"
            echo "HF cache : $HF_HUB_CACHE"
            echo ""
            echo "Download:"
            echo "  hf download unsloth/GLM-5-GGUF --cache-dir $HF_HUB_CACHE"
            echo ""
            echo "Run (single GPU):"
            echo "  llama-cli -m ./.models/gguf/<file>.gguf -ngl 99 -c 8192 -p \"Hello\""
            echo ""
            echo "Run (2x A100):"
            echo "  llama-cli -m ./.models/gguf/<file>.gguf -ngl 99 --tensor-split 1,1 -c 8192 -p \"Hello\""
            echo ""
            echo "Server (OpenAI-ish HTTP):"
            echo "  llama-server -m ./.models/gguf/<file>.gguf -ngl 99 --tensor-split 1,1 -c 8192 --port 8000"
          '';
        };
      });
}
