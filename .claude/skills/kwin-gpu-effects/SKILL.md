---
name: kwin-gpu-effects
description: >-
  Work with KWin GPU shader effects on KDE Plasma 6 / Wayland (CachyOS / Arch):
  enable, disable, and tune Better Blur (forceblur) and kwin-effect-shaders;
  author and install custom GLSL shaders; diagnose no-blur / stutter / compositor
  / build issues. Use whenever the user wants to change desktop blur, frosted
  glass, rounded corners, sharpening (CAS), color grading, or any GPU UI effect.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# KWin GPU effects

Procedures for driving the GPU shader effects in this pack (Layer 9,
`9-gpu-effects/`). The whole Plasma 6 UI is already GPU-composited (KWin via
OpenGL/EGL; shell via the QtQuick scene graph) — you are changing *which* shaders
run in that pipeline, not adding GPU rendering.

**Always Wayland.** X11 disables compositing for fullscreen apps and breaks these
effects. Confirm with `echo $XDG_SESSION_TYPE` (must be `wayland`).

## Always do this first: read current state

Run the bundled inspector before changing anything — it prints which blur/shader
effects are active and flags the stock-vs-forceblur conflict:

```bash
bash .claude/skills/kwin-gpu-effects/scripts/effect-state.sh
```

After **any** config change, apply it live (no logout needed for effect toggles):

```bash
qdbus6 org.kde.KWin /KWin reconfigure
```

## The three effects and their exact IDs (verified)

KWin effects are toggled in `kwinrc` under `[Plugins]` with the key `<id>Enabled`,
and configured under `[Effect-<id>]`. The IDs here are confirmed, not guessed:

| Effect | Plugin id | Enable key | Config group | Source |
|---|---|---|---|---|
| Stock blur (Layer 1) | `blur` | `blurEnabled` | `Effect-blur` | ships with KWin |
| Better Blur | `forceblur` | `forceblurEnabled` | `Effect-forceblur` | AUR `kwin-effects-forceblur` |
| Desktop shaders | `kwin_effect_shaders` | `kwin_effect_shadersEnabled` | — | built from source (Layer 9) |

**Critical conflict:** `blur` and `forceblur` are the same effect forked — only one
may run. Enabling one **requires disabling the other**, or blur breaks entirely.

## Common tasks

### Switch stock blur ↔ Better Blur
```bash
# stock -> Better Blur
kwriteconfig6 --file kwinrc --group Plugins --key blurEnabled      false
kwriteconfig6 --file kwinrc --group Plugins --key forceblurEnabled true
qdbus6 org.kde.KWin /KWin reconfigure
```
Reverse the two booleans to go back. The pack's `9-gpu-effects/revert.sh` does the
reverse and only restores stock blur if forceblur was actually active.

### Tune blur strength
`BlurStrength` (0–15) is honoured by **both** blur effects — but write it to the
group of the effect that is actually **active** (the inspector prints which one):
- stock blur active  → group `Effect-blur`
- Better Blur active → group `Effect-forceblur`

Writing it to the *inactive* effect's group silently does nothing.
```bash
# whichever blur is on — e.g. stock blur, dialing it down to subtle:
kwriteconfig6 --file kwinrc --group Effect-blur --key BlurStrength 8
qdbus6 org.kde.KWin /KWin reconfigure
```
**15 is the maximum** (Layer 1's "heavy" default) — from there you can only go
*subtler*, not stronger. If the user wants "more blur" and it's already 15, that
needs Better Blur (more iterations) or Background Contrast, not a bigger number.
Better Blur has many more keys (rounded corners, brightness/contrast/saturation,
static-blur, per-window force-blur rules). **Do not guess key names** — they drift
across versions. To discover the real keys: set the option once in *System Settings
→ Desktop Effects → Better Blur (gear)*, then read them back:
```bash
kreadconfig6 --file kwinrc --group Effect-forceblur --key <Key>
# or dump the whole group:
awk '/^\[Effect-forceblur\]/{f=1;next}/^\[/{f=0}f' ~/.config/kwinrc
```

### Turn the desktop shader pass on
The `kwin_effect_shaders` plugin can be *enabled* yet show nothing — the visible
pass is gated behind a toggle shortcut (off by default, safe). To make it visible:
1. `kwriteconfig6 --file kwinrc --group Plugins --key kwin_effect_shadersEnabled true && qdbus6 org.kde.KWin /KWin reconfigure`
2. Bind a key: *System Settings → Shortcuts → KWin → "Toggle Shaders"*, then press it.

### Pick / tune which shaders run
Shaders live in `~/.local/share/kwin-effect-shaders_shaders/`; the active set and
their parameters are controlled by `1_settings.glsl` in that dir. Good low-cost
defaults: **CAS** (contrast-adaptive sharpening) + **deband**. Heavy: FakeHDR,
adaptive-sharpen. Edit `1_settings.glsl`, then reconfigure.

### Author + install a custom GLSL shader (for kwin-effect-shaders)
This is the easy path for a one-off filter (vignette, tint, CRT, etc.):
1. Drop a `.glsl` file into `~/.local/share/kwin-effect-shaders_shaders/` following
   the form of the existing shaders there (read one first — they expose a `main()`
   that reads `texture(...)` and writes the post-processed color).
2. Reference/enable it from `1_settings.glsl`.
3. Requires **GLSL 1.40+** (desktop GL) or **ES 3.0+**. `qdbus6 ... reconfigure`,
   then toggle the pass to see it.

### Author a custom KWin effect with QSB shaders (advanced)
For a *true* per-window or compositor effect (not a screen post-process), write a
KWin effect that loads `.qsb` shaders (Plasma 6's Qt6 shader format): author GLSL,
compile with the `qsb` tool, load via the effect's `ShaderManager`. This is real
C++/QML plugin work — scaffold from an existing effect (e.g. the KDE invert or
KDE-Rounded-Corners source) rather than from scratch. Reference:
https://discuss.kde.org/t/help-with-custom-qsb-shaders-in-kwin-plasma-6-wayland/39830

## Troubleshooting

- **No blur at all** → both `blur` and `forceblur` enabled (conflict), or both
  disabled. Check with the inspector; ensure exactly one is `true`. Also: a window
  must have a **translucent** region for stock blur to show (Better Blur's
  force-blur bypasses this).
- **Better Blur installed but greyed out / missing** → AUR build is for the wrong
  KWin version. Upstream `kwin-effects-forceblur` is archived; install the
  maintained fork `kwin-effects-glass` instead.
- **Shaders effect won't build** → it compiles against KWin's *private* headers and
  breaks across KWin point releases. Ensure `extra-cmake-modules kwin cmake` are
  installed; if it still fails, it's a version mismatch — not fixable without an
  upstream patch. The desktop is unaffected by the failed build.
- **Stutter / cursor lag under heavy shader load** → set, in
  `~/.config/environment.d/kwin-gpu.conf` (then log out/in):
  - `KWIN_DRM_NO_AMS=1` — disable atomic modesetting
  - `KWIN_FORCE_SW_CURSOR=1` (or `0`) — toggle software cursor
- **Wrong GPU on a hybrid/dual-GPU box** → `MESA_VK_DEVICE_SELECT=vendorID:deviceID`
  or `DRI_PRIME=1` in the same `environment.d` file.
- **Effects revert after reboot but not after reconfigure** → you edited `kwinrc`
  but skipped `qdbus6 org.kde.KWin /KWin reconfigure`.

## Driver baseline (CachyOS)

Effects are only as smooth as the ICD: AMD `vulkan-radeon mesa` · Intel
`vulkan-intel` (Broadwell+) · NVIDIA proprietary `nvidia`. KWin's Vulkan backend is
still experimental as of 2026 — everything here is GLSL on the OpenGL/EGL backend.

## Live tweak vs lasting change — handle them differently

Decide which the user is actually asking for before you touch anything:

- **Ephemeral / "let me see it now"** (experimenting, tuning a value, trying a look):
  change **only live config** (`kwriteconfig6` + `qdbus6 … reconfigure`). Do **NOT**
  edit the pack's source scripts for a throwaway tweak — leave `1-base/` and
  `9-gpu-effects/` alone. Editing a tracked install script for a quick experiment is
  surprising and unwanted.
- **Lasting / "make this the default"**: this pack's principle is that every standing
  system tweak goes through an install/revert pair. Only then, mirror the change into
  the owning layer so it survives a reinstall and stays undoable —
  `9-gpu-effects/{install,revert}.sh` for the GPU effects, or
  `1-base/whitesur-cachyos-macos.sh` for the stock-blur default.

When it's ambiguous, treat it as **ephemeral** (live only) and tell the user the
one-line command to persist it if they want it to stick.
