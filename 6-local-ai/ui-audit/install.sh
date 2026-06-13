#!/usr/bin/env bash
# Layer 6 · UI-audit — the grounded daily KDE-theming audit agent for Hermes.
#
# Deploys the kde-plasma-customization skill (SKILL.md + references + the
# deterministic collector/applier scripts) into the local Hermes profile, and
# optionally registers the daily cron job. The applier is the guardrail: the
# local LLM proposes, deterministic code disposes (state-bound assertion,
# allowlist, earned auto-apply, backup+verify+revert, deterministic report).
#
# Requires Hermes (Layer 6's Ollama/Hermes stack). Each item is opt-in; -y for all.
# Run as your normal user: bash 6-local-ai/ui-audit/install.sh   (add -y)
# Reversible via revert.sh (add --purge to also delete the audit runtime/ledger).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] && { echo "Run as your normal user, not root."; exit 1; }

ALL=0; case "${1:-}" in -y|--yes) ALL=1 ;; -h|--help)
  echo "Usage: bash install.sh [-y]"; exit 0 ;; esac
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
msg(){ printf '\n\033[1m:: %s\033[0m\n' "$1"; }
ask(){ [ "$ALL" = 1 ] && return 0; printf '  %s? [Y/n] ' "$1"
       read -r r </dev/tty 2>/dev/null || r=n; case "$r" in [nN]*) return 1 ;; *) return 0 ;; esac; }

HHOME="${HERMES_HOME:-$HOME/.hermes}"
SKILL_DST="$HHOME/skills/devops/kde-plasma-customization"
RUNTIME="$HHOME/ui-audit"
VENV_PY="$HHOME/hermes-agent/venv/bin/python"

echo ":: Layer 6 · UI-audit (grounded daily theming agent)."
if [ ! -d "$HHOME" ]; then
  warn "No Hermes home at $HHOME — install Layer 6 (Ollama + Hermes) first. Skipping."
  exit 0
fi

# --- deploy the skill (source of truth lives here in the repo) -------------
if ask "Deploy the kde-plasma-customization skill into $SKILL_DST"; then
  msg "Deploying skill…"
  mkdir -p "$SKILL_DST/references" "$SKILL_DST/scripts"
  cp "$HERE/skill/SKILL.md"            "$SKILL_DST/SKILL.md"
  cp "$HERE/skill/references/"*.md     "$SKILL_DST/references/"
  cp "$HERE/skill/scripts/"*.py "$HERE/skill/scripts/"*.sh "$SKILL_DST/scripts/"
  chmod +x "$SKILL_DST/scripts/"*.py "$SKILL_DST/scripts/"*.sh 2>/dev/null || true
  mkdir -p "$RUNTIME/state" "$RUNTIME/pending" "$RUNTIME/backups"
  ok "skill + runtime dirs deployed"
  # Sanity: the scripts must at least parse with the system python.
  if python3 -c "import ast,sys; [ast.parse(open(f).read()) for f in sys.argv[1:]]" \
       "$SKILL_DST/scripts/ui-audit-collect.py" "$SKILL_DST/scripts/ui-audit-apply.py" 2>/dev/null; then
    ok "collector + applier parse clean"
  else
    warn "script parse check failed — inspect $SKILL_DST/scripts/"
  fi
fi

# --- register the daily cron job (idempotent by name) ----------------------
if ask "Register the daily UI-audit cron job (09:00, delivers to Hermes cron output)"; then
  if [ ! -x "$VENV_PY" ]; then
    warn "Hermes venv not found at $VENV_PY — skipping cron registration."
  else
    msg "Registering cron job…"
    UIA_PROMPT_FILE="$HERE/cron-prompt.txt" UIA_SKILLDIR="$SKILL_DST" \
    "$VENV_PY" - <<'PY'
import os, json, pathlib
from cron import jobs
NAME = "Daily UI audit"
home = pathlib.Path(os.environ.get("HERMES_HOME", str(pathlib.Path.home() / ".hermes")))
jobs_file = home / "cron" / "jobs.json"
existing = []
if jobs_file.exists():
    try:
        data = json.loads(jobs_file.read_text())
        existing = data if isinstance(data, list) else data.get("jobs", [])
    except Exception:
        existing = []
if any(j.get("name") == NAME for j in existing):
    print("  \033[32m✓\033[0m cron job already present — leaving it")
else:
    prompt = pathlib.Path(os.environ["UIA_PROMPT_FILE"]).read_text()
    job = jobs.create_job(prompt=prompt, schedule="0 9 * * *", name=NAME,
                          deliver="local", skills=["kde-plasma-customization"],
                          workdir=os.environ["UIA_SKILLDIR"])
    jid = job.get("id")
    try:
        nr = jobs.compute_next_run(job["schedule"])
        jobs.update_job(jid, {"next_run": nr})
    except Exception:
        nr = None
    print(f"  \033[32m✓\033[0m created cron job {jid} (daily 09:00) next_run={nr}")
PY
  fi
fi

# --- usage focus (opt-in, privacy-respecting, local-only) ------------------
if ask "Enable usage-focused refinement (reuses KDE app-usage scores, local-only)"; then
  msg "Enabling usage focus…"
  if python3 "$SKILL_DST/scripts/ui-audit-usage.py" --grant-consent >/dev/null 2>&1; then
    ok "consent granted — data under $RUNTIME/usage/ (0600)"
    echo "   Privacy: app-level only (KActivities initiatingAgent counts; NEVER"
    echo "   resource paths/URLs/titles), favourites, and the audit ledger."
    echo "   Network-isolated via run-sandboxed.sh; 30-day retention. Forget anytime:"
    echo "     python3 $SKILL_DST/scripts/ui-audit-usage.py --forget"
  else
    warn "could not grant consent (is python3 available?)"
  fi
fi

cat <<EOF

$(printf '\033[1m:: UI-audit component done.\033[0m')
   Skill : $SKILL_DST
   Run   : python3 $SKILL_DST/scripts/ui-audit-collect.py   (then the applier)
   Daily : delivered to $HHOME/cron/output/<job_id>/ ; report at $RUNTIME/report.md
   Note  : nothing auto-applies until you approve a key once (earned autonomy).
EOF
