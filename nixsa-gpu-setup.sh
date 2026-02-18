# nixsa GPU passthrough setup
# Source this in your .bashrc or job script:
#   source /path/to/nixsa-gpu-setup.sh

# Only set up if NVIDIA devices are present (i.e. on a GPU node).
if [ -e /dev/nvidiactl ]; then
  NIXSA_BWRAP_ARGS=""
  for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [ -e "$dev" ] && NIXSA_BWRAP_ARGS="$NIXSA_BWRAP_ARGS --dev-bind $dev $dev"
  done
  for cap in /dev/nvidia-caps/*; do
    [ -e "$cap" ] && NIXSA_BWRAP_ARGS="$NIXSA_BWRAP_ARGS --dev-bind $cap $cap"
  done
  export NIXSA_BWRAP_ARGS="${NIXSA_BWRAP_ARGS# }"
fi

