#!/usr/bin/env bash
# Fetch the Poly Haven CC0 stone textures + gothic prop models the Layer-10
# "hexen" dungeon scene needs (idempotent — skips files already present).
# Thin wrapper over fetch-hexen-assets.py so it lives next to the other Layer-10
# shell entrypoints; all the real work (Poly Haven API + CDN) is in the .py.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/fetch-hexen-assets.py" "$@"
