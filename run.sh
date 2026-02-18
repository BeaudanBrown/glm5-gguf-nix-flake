llama-cli -m ./cache/models--unsloth--GLM-5-GGUF/snapshots/ff5c55c3470d73e038cc33301d66f197b679660e/UD-Q4_K_XL/GLM-5-UD-Q4_K_XL-00001-of-00010.gguf \
        --fit on \
        --ctx-size 16384 \
        --batch-size 512 \
        --ubatch-size 128 \
        --flash-attn auto \
        --threads 95
