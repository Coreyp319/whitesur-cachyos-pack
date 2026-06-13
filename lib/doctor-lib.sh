# lib/doctor-lib.sh — shared helpers for per-layer doctor.sh drift checks.
#
# A layer's doctor.sh sources this, calls gate/check/note, then doctor_done.
# It answers "does the live system still match what this layer installs?" — the
# audit, made repeatable. Source of truth stays the layer's install.sh; this just
# verifies the standing result.
#
# Exit codes (consumed by `nimbus status`):
#   0   OK            — installed and every check passed
#   1   DRIFTED       — installed but a check failed (usually fixed by re-running install)
#   10  NOT-INSTALLED — the gate marker is absent; detail checks skipped
# Set NIMBUS_QUIET=1 to suppress per-check lines (status renders just the code).

: "${NIMBUS_QUIET:=0}"
_dc_fail=0

_say(){ [ "$NIMBUS_QUIET" = 1 ] || printf '%b\n' "$1"; }

# gate "what's missing" <cmd...> : if <cmd> fails, the layer isn't installed.
gate(){ local msg="$1"; shift
  "$@" >/dev/null 2>&1 && return 0
  _say "  \033[2m–\033[0m not installed ($msg)"
  exit 10
}

# check "label" <cmd...> : PASS if <cmd> exits 0, else FAIL (counts as drift).
check(){ local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    _say "  \033[32m✓\033[0m $label"
  else
    _say "  \033[31m✗\033[0m $label"
    _dc_fail=$((_dc_fail + 1))
  fi
}

# note "text" : informational only (optional/user-toggleable sub-features).
note(){ _say "  \033[2m·\033[0m $1"; }

# has_pkg <pkg...> : true if ANY of the named packages is installed.
# Per-package (no pipe): `pacman -Qq a b` exits non-zero if any arg is missing,
# which under `set -o pipefail` would fail the whole check even when one matched.
has_pkg(){ local p; for p in "$@"; do pacman -Qq "$p" >/dev/null 2>&1 && return 0; done; return 1; }

doctor_done(){ [ "$_dc_fail" -eq 0 ]; exit $?; }
