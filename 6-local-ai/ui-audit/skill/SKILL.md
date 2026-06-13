---
trigger: always
name: kde-plasma-customization
description: Customize and audit KDE Plasma desktop theming, color schemes, fonts, widgets, KWin effects, and panel layouts programmatically.
---
# KDE Plasma Customization & Troubleshooting

Customize and audit KDE Plasma (Wayland/X11) desktop environments — theming, color schemes, fonts, widgets, KWin effects, and panel layout — primarily on Arch/CachyOS.

## When to Use

- User wants to change UI colors, themes, fonts, or behavior in KDE Plasma
- Customizing slider tracks, window decorations, panel appearance, cursor/icon themes
- Diagnosing why color/theme changes aren't visually applying
- Auditing current desktop configuration state
- Modifying `.colors`, `kdeglobals`, `kwinrc`, `plasmashellrc` programmatically

## Prerequisites

- KDE Plasma 6 (KF6) on Arch/CachyOS with `plasma-workspace`, `kde-cli-tools`, `spectacle` available
- Agent terminal runs headless (no `$DISPLAY`/Wayland socket) — use config parsing over screenshots

## Core Architecture: Color Resolution Priority

KDE Plasma resolves colors in this order (highest wins):
1. **LookAndFeelPackage** (`~/.config/kdeglobals[KDE].LookAndFeelPackage`) — installed themes ship their own `.colors` and OVERRIDE user color schemes
2. **User ColorScheme** (`~/.config/kdeglobals[KDE].ColorScheme`) — references `~/.local/share/color-schemes/<name>.colors`
3. **System defaults** — bundled in `/usr/share/color-schemes/`

> ⚠️ If LookAndFeel is set AND you set a custom ColorScheme, LookAndFeel wins on session load. Either clear LookAndFeel or let the installed theme manage colors.

## Configuration Files

- `kdeglobals` (`~/.config/`) — ColorScheme, LookAndFeel, WidgetStyle (Kvantum/Breeze), contrast, FrameContrast, fonts
- `.colors` files (`~/.local/share/color-schemes/` or `/usr/share/color-schemes/`) — Per-role colors: View, Button, Selection, Header, Tooltip, Window, Complementary
- `kwinrc` (`~/.config/`) — KWin effects (blur, aurora, glide), tiling config, window rules
- `plasmashellrc` (`~/.config/`) — Panel containments, wallpaper, desktop plugins
- `kvantum.kvconfig` (`~/.config/Kvantum/`) — Active Kvantum widget theme; MUST be set if WidgetStyle=kvantum
- `iconrc` (`~/.config/`) — Icon theme name

## Steps: Modify a Color Role (e.g., Slider Track)

1. **Check active LookAndFeel:** `grep LookAndFeel ~/.config/kdeglobals` — if present, expect user colors to be overridden at login
2. **Copy base scheme to userland:** `cp /usr/share/color-schemes/BreezeLight.colors ~/.local/share/color-schemes/MyScheme.colors`
3. **Edit the target role:** Sections like `[Colors:View]`, `[Colors:Button]`, `[Colors:Selection]`. Modify `BackgroundNormal`, `ForegroundNormal`, or `DecorationFocus` (RGB comma-separated)
4. **Set scheme in kdeglobals:** Ensure `[KDE].ColorScheme=MyScheme`
5. **Invalidate cache hash:** `sed -i '/^ColorSchemeHash=/d' ~/.config/kdeglobals` — stale hash blocks live apply
6. **Apply:** `plasma-apply-colorscheme MyScheme`

## Daily UI Audit (grounded + tiered auto-apply)

Do NOT hand-run `kreadconfig6`/`grep` and narrate the results — a local model
confabulates that way. Use the deterministic toolkit, which reads the real
config (so you can only report values that exist) and owns the writes (so a
wrong proposal can't reach a load-bearing key):

```bash
ST=~/.hermes/ui-audit/state/state.json
# 1. Snapshot the real state (+ computed WCAG contrast). Prints state.json path.
python3 scripts/ui-audit-collect.py
# 2. Read state.json + the ledger, then write ops.json (schema in the protocol).
# 3. Dry-run (--state is REQUIRED), read it, then apply:
python3 scripts/ui-audit-apply.py --ops ops.json --state "$ST"            # dry-run
python3 scripts/ui-audit-apply.py --ops ops.json --state "$ST" --apply    # auto (earned only) + stage
# Approve a staged op (applies it AND graduates its key to auto next time):
python3 scripts/ui-audit-apply.py --approve <pending_id>
# Undo a whole run:
python3 scripts/ui-audit-apply.py --revert <run_id>
# Optional: refresh the usage signal so the report FOCUSES on apps you use
# (opt-in, app-level, network-isolated; advisory ranking only — never changes
# what may be applied). Apply step picks up usage.json automatically.
bash scripts/run-sandboxed.sh ui-audit-usage.py
```

**Read `references/audit-protocol.md` first** — it is the operating contract.
Key invariants the scripts now ENFORCE (not just request): every op must carry
`current_asserted` = the exact `state.json` value (checked vs snapshot + live, or
rejected); only snapshotted/allowlisted keys are touchable; **nothing
auto-applies until you've approved that key once** (autonomy is earned); and the
applier emits the report — **relay it verbatim, don't author your own findings
prose** (your prose isn't grounded; the report is).

## Common Pitfalls

> These are diagnostic PATTERNS, not a checklist of findings. Cite one only when
> `state.json` shows it is actually true here (with the numbers). Reciting them
> as discoveries is the failure this skill exists to prevent.

- **Color change doesn't visually land:** LookAndFeel overrides user ColorScheme. Fix: clear LookAndFeel or apply colors through theme package.
- **`plasma-apply-colorscheme` says "already set" but no visual change:** Stale `ColorSchemeHash` in kdeglobals. Fix: delete hash line, re-run apply.
- **Kvantum active but widgets look wrong:** No `kvantum.kvconfig` with theme declared. Fix: set `[General]theme=WhiteSur-dark` in `~/.config/Kvantum/kvantum.kvconfig`.
- **Font weight too thin at 11pt:** Inter 400 Regular not legible in Plasma UI. Fix: increase to weight 500 in Font config string (`Inter,11,-1,5,500,...`).
- **Slider filled portion stays the accent colour:** the filled/elapsed track is `[Colors:Selection].BackgroundNormal` (the system accent), not the View role. Editing `View` won't change it. Recolour `Selection.BackgroundNormal`.

## Color Role Mapping (Quick Reference)

Native Breeze (custom QML controls + Kvantum may override — see the cheatsheet):
- **Slider filled/elapsed track** → `[Colors:Selection].BackgroundNormal` (accent)
- **Slider handle FILL** → `[Colors:Button].BackgroundNormal`
- **Slider handle focus/hover ring** → `[Colors:Button].DecorationFocus` / `DecorationHover` (outline only — NOT the knob fill)
- **Slider unfilled groove** → derived (`Window` text @ ~20%), not a direct `BackgroundNormal`
- **Window/dialog background** → `[Colors:Window].BackgroundNormal`
- **Panel/taskbar** → Plasma Desktop SVG theme, NOT the colour scheme
- **Lock/logout/fullscreen surfaces** → `[Colors:Complementary]`

## See Also

- `references/audit-protocol.md` — the daily-audit operating contract (grounding rules, ops.json schema, tiers/allowlist, ledger/dedup, report shape)
- `references/color-theory-accessibility.md` — WCAG contrast math, role→pairing map, OKLCH dark-theme rules
- `references/color-role-cheatsheet.md` — full mapping of KDE color roles to UI elements
- `scripts/ui-audit-collect.py` — deterministic state.json collector (no LLM); `scripts/ui-audit-apply.py` — guardrail enforcer (allowlist/tiers/assert/backup/verify/ledger)