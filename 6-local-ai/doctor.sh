#!/usr/bin/env bash
# Layer 6 drift check — on-GPU Ollama (KV-cache drop-in) + Hermes models.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"; . "$SELF/../lib/doctor-lib.sh"

gate "ollama not installed" has_pkg ollama-cuda ollama

models=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -c '^hermes' || true)
check "ollama.service enabled"               [ "$(systemctl is-enabled ollama.service 2>/dev/null)" = enabled ]
check "KV-cache systemd drop-in installed"   [ -f /etc/systemd/system/ollama.service.d/10-kv-cache.conf ]
check "at least one Hermes model present"    [ "${models:-0}" -ge 1 ]
note  "GPU runner: $(has_pkg ollama-cuda && echo ollama-cuda || echo 'ollama (CPU fallback?)')"

doctor_done
