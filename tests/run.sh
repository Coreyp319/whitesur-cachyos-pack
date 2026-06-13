#!/usr/bin/env bash
# Test suite for the WhiteSur CachyOS pack.
#
# Static + real-engine checks over the whole repo. Designed to run anywhere:
# each check degrades to SKIP if its tool is missing (so CI without PyQt6/Qt
# still runs the rest). Exit 0 = all pass, non-zero = at least one failure.
#
#   bash tests/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0; skip=0
ok(){  printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skp(){ printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip+1)); }
hdr(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

files(){ git ls-files "$1"; }   # tracked files only — ignores build junk

# 1. Shell scripts parse ----------------------------------------------------
hdr "Shell syntax (bash -n)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if bash -n "$f" 2>/tmp/_t; then ok "$f"; else bad "$f"; sed 's/^/       /' /tmp/_t; fi
done < <(files '*.sh')

# 2. Python compiles --------------------------------------------------------
hdr "Python compile (py_compile)"
if command -v python3 >/dev/null; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if python3 -m py_compile "$f" 2>/tmp/_t; then ok "$f"; else bad "$f"; sed 's/^/       /' /tmp/_t; fi
  done < <(files '*.py')
else skp "python3 not found"; fi

# 3. SVG well-formedness (Kvantum themes etc.) ------------------------------
hdr "SVG well-formedness (xmllint)"
if command -v xmllint >/dev/null; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if xmllint --noout "$f" 2>/tmp/_t; then ok "$f"; else bad "$f"; sed 's/^/       /' /tmp/_t; fi
  done < <(files '*.svg')
else skp "xmllint not found (SVG checks)"; fi

# 4. JSON + XML config validity ---------------------------------------------
hdr "JSON / XML config validity"
if command -v python3 >/dev/null; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/tmp/_t; then ok "$f"; else bad "$f"; sed 's/^/       /' /tmp/_t; fi
  done < <(files '*.json')
else skp "python3 not found (JSON checks)"; fi
if command -v xmllint >/dev/null; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if xmllint --noout "$f" 2>/tmp/_t; then ok "$f"; else bad "$f"; sed 's/^/       /' /tmp/_t; fi
  done < <(files '*.xml')
fi

# 5. QML instantiation — the blank-dialog catcher ---------------------------
# Constructs the aurora config UI in a real Qt engine; catches errors qmllint
# misses (invalid signal handlers, bad layer.effect, etc.).
hdr "QML instantiation (real Qt engine)"
QMLDIR="9-gpu-effects/interactive-bg/contents/ui"
if [ -d "$QMLDIR" ] && python3 -c "import PyQt6" 2>/dev/null; then
  out="$(QT_QPA_PLATFORM=offscreen python3 tests/qml_instantiate.py \
           "$QMLDIR/AuroraSlider.qml" "$QMLDIR/AuroraColorButton.qml" \
           "$QMLDIR/AuroraComboBox.qml" "$QMLDIR/config.qml" 2>&1)"
  printf '%s\n' "$out"
  pass=$((pass + $(grep -c '  PASS' <<<"$out")))
  fail=$((fail + $(grep -c '  FAIL' <<<"$out")))
else
  skp "PyQt6 / aurora UI not available (QML instantiation)"
fi

# Summary -------------------------------------------------------------------
printf '\n\033[1m== Summary ==\033[0m  \033[32m%d passed\033[0m, \033[31m%d failed\033[0m, \033[33m%d skipped\033[0m\n' \
  "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
