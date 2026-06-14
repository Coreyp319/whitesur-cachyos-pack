#!/usr/bin/env bash
# One-time setup for DLSS Ray Reconstruction on the Layer-10 ray-traced "hexen" wallpaper.
# Clones NVIDIA's public DLSS SDK (v310.4.0) + Khronos Vulkan headers into the locations
# run.sh auto-detects, so the next launch builds `--features dlss` and denoises the Solari
# ray-traced output. NO SUDO — only Vulkan *headers* are cloned (not the system package).
# Idempotent. Needs git + clang (clang for the dlss_wgpu bindgen build).
#
# License: the DLSS SDK is NVIDIA's; comply with its LICENSE.txt if you redistribute the
# runtime libs. This only clones it locally for a personal build.
set -euo pipefail

SDK="${DLSS_SDK:-$HOME/.local/share/nimbus-dlss-sdk}"
VK="${VULKAN_SDK:-$HOME/.local/share/nimbus-vulkan-headers}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v git >/dev/null   || { echo "git is required" >&2; exit 1; }
command -v clang >/dev/null || echo "warning: clang not found — the dlss_wgpu build (bindgen) will need it" >&2

if [ -f "$SDK/lib/Linux_x86_64/libnvsdk_ngx.a" ]; then
    echo "✓ DLSS SDK already present: $SDK"
else
    echo "cloning NVIDIA DLSS SDK v310.4.0 → $SDK (a few hundred MB)…"
    rm -rf "$SDK"
    git clone --depth 1 -b v310.4.0 https://github.com/NVIDIA/DLSS.git "$SDK"
fi

if [ -f "$VK/include/vulkan/vulkan.h" ]; then
    echo "✓ Vulkan headers already present: $VK"
else
    echo "cloning Vulkan headers → $VK…"
    rm -rf "$VK"
    git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git "$VK"
fi

echo
echo "DLSS ready. The next launch builds + runs with ray reconstruction:"
echo "  NIMBUS_FLUX_WALLPAPER=1 bash $HERE/run.sh"
