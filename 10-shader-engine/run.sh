#!/usr/bin/env bash
# Nimbus Flux — launch the standalone GPU compute-shader fluid engine (Layer 10).
#
#   move / drag cursor : push the fluid and inject dye
#   1 / 2 / 3          : style — ink / mercury / water
#   D                  : toggle light / dark
#   Esc or close       : quit
#
# Env overrides (optional):
#   NIMBUS_FLUX_STYLE=0|1|2   start in a given style
#   NIMBUS_FLUX_DARK=0|1      start light/dark
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nimbus-flux"
export PATH="$HOME/.cargo/bin:$PATH"

# DLSS Ray Reconstruction (optional): if the NVIDIA DLSS SDK + Vulkan headers are present,
# build + run the Solari ray-traced path with hardware denoising. The build needs DLSS_SDK
# + VULKAN_SDK; the runtime needs the DLSS .so on the library path. Without the SDK,
# everything still builds and runs — just without the denoiser. Get the SDK with:
#   bash 10-shader-engine/setup-dlss.sh   (clones the DLSS SDK + Vulkan headers, no sudo)
export DLSS_SDK="${DLSS_SDK:-$HOME/.local/share/nimbus-dlss-sdk}"
export VULKAN_SDK="${VULKAN_SDK:-$HOME/.local/share/nimbus-vulkan-headers}"
FEATURES=()
if [[ -f "$DLSS_SDK/lib/Linux_x86_64/libnvsdk_ngx.a" && -f "$VULKAN_SDK/include/vulkan/vulkan.h" ]]; then
    export LD_LIBRARY_PATH="$DLSS_SDK/lib/Linux_x86_64/rel${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    FEATURES=(--features dlss)
else
    unset DLSS_SDK VULKAN_SDK   # avoid tripping dlss_wgpu's build if only partially set up
fi

# Prefer an optimised release binary; fall back to debug; build release if neither.
BIN="$DIR/target/release/nimbus-flux"
if [[ ${#FEATURES[@]} -gt 0 ]]; then
    # ensure the DLSS-enabled release binary is current (cargo no-ops if nothing changed)
    (cd "$DIR" && cargo build --release "${FEATURES[@]}")
    # NGX dlopens the DLSS feature libs from next to the executable — copy them there
    cp -u "$DLSS_SDK"/lib/Linux_x86_64/rel/libnvidia-ngx-dlss*.so* "$DIR/target/release/" 2>/dev/null || true
elif [[ ! -x "$BIN" ]]; then
    if [[ -x "$DIR/target/debug/nimbus-flux" ]]; then
        BIN="$DIR/target/debug/nimbus-flux"
    else
        echo "First run — building release (this takes a few minutes)…"
        (cd "$DIR" && cargo build --release)
    fi
fi
[[ -x "$BIN" ]] || BIN="$DIR/target/debug/nimbus-flux"

# bevy resolves assets relative to the executable by default; point it at the
# crate so shaders/fluid.wgsl is found whether run from debug, release, or installed.
export BEVY_ASSET_ROOT="$DIR"
exec "$BIN" "$@"
