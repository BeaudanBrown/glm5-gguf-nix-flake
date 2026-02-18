# nixsa GPU passthrough setup
# Source this in your .bashrc or job script:
#   source /path/to/nixsa-gpu-setup.sh

# Only set up if NVIDIA devices are present (i.e. on a GPU node).
if [ -e /dev/nvidiactl ]; then
  NIXSA_BWRAP_ARGS=""

  # --- Device nodes ---
  for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [ -e "$dev" ] && NIXSA_BWRAP_ARGS="$NIXSA_BWRAP_ARGS --dev-bind $dev $dev"
  done
  for cap in /dev/nvidia-caps/*; do
    [ -e "$cap" ] && NIXSA_BWRAP_ARGS="$NIXSA_BWRAP_ARGS --dev-bind $cap $cap"
  done

  # --- NVIDIA driver libraries ---
  # Bind-mount each NVIDIA .so from the host into the sandbox so the
  # Nix-built CUDA runtime can dlopen() them.  We bind individual files
  # (ro-bind) rather than all of /lib64 to avoid shadowing Nix's glibc.
  for _so in \
    /lib64/libcuda.so* \
    /lib64/libcudadebugger.so* \
    /lib64/libcuda_wrapper.so* \
    /lib64/libnvidia*.so* \
    /lib64/libnvcuvid.so* \
    /lib64/libvdpau_nvidia.so* ; do
    [ -e "$_so" ] && NIXSA_BWRAP_ARGS="$NIXSA_BWRAP_ARGS --ro-bind $_so $_so"
  done

  # nvidia-smi and nvidia-persistenced are handy inside the sandbox.
  for _bin in /usr/bin/nvidia-smi /usr/bin/nvidia-persistenced; do
    [ -e "$_bin" ] && NIXSA_BWRAP_ARGS="$NIXSA_BWRAP_ARGS --ro-bind $_bin $_bin"
  done

  export NIXSA_BWRAP_ARGS="${NIXSA_BWRAP_ARGS# }"
  unset _so _bin
fi

