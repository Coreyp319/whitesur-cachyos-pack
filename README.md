# Nimbus CachyOS pack — macOS-style desktop + OS customization

A personal **CachyOS + KDE Plasma 6 (Wayland)** customization. Layers 1–4 turn a
stock install into a cohesive macOS-style desktop; Layers 5–6 add general system
quality-of-life and a local AI stack that have nothing to do with the *look*;
Layers 7–9 add Apple-style notifications, Dolphin Quick Look, and GPU shader
effects. Nine independent layers — install any subset.

```bash
bash install.sh          # interactive, pick layers
bash install.sh -y       # install all nine, no prompts
bash revert.sh           # undo (add --purge to delete installed files)
```

> Run as your **normal user** (not root). `sudo` is used for packages, Layer 3's
> milou patch, Layer 4's SDDM theming, and Layer 5's installs. **Log out / back
> in** afterward to activate `Meta+Space` and `Meta+Ctrl+T` (Wayland binds global
> shortcuts at login).

---

## Layers

### 1 · Base mac desktop  — `1-base/`
WhiteSur global theme (Plasma + Qt/Kvantum + GTK light & dark), icons, mac
cursors, **Inter** UI font + **MesloLGS** (Menlo-like) mono for Konsole/code ·
Big Sur wallpaper · floating **auto-hide dock** with Launchpad + pinned apps,
a **curated system tray** (essentials shown, the rest collapsed — still editable
in Configure System Tray) and an **Inter panel clock** ·
**Spotlight** (centered KRunner, `Meta+Space`) + file search · mac-style window
animations (scale/squash/maximize at a ~0.9 duration tuned to match the Spotlight
motion), Mission-Control hot corner, edge tiling · **WhiteSur window decoration**
(Aurorae traffic-light buttons) · heavy blur · frosted menus & Konsole · mac-style
**font smoothing** (no hinting + RGB subpixel) · **calibrated text hierarchy**
(one accent + one secondary tier across every surface, fixing leftover-Breeze
accent/secondary drift) · 10px floating dock bottom-margin ·
**WhiteSur boot splash** · top-right notifications · **one-click light↔dark toggle**
(dock icon / Spotlight / `Meta+Ctrl+T`) that also flips **window decoration, splash,
and the Big Sur wallpaper** light↔dark · Firefox set to **follow the system**
light/dark theme · QoL: NumLock on at login, Night Color (warm evenings).

⚠ **Replaces your panel/dock** (any panel with a task manager is rebuilt as the
mac dock) and restarts plasmashell. Reverting: System Settings → Global Theme →
Breeze, then remove the dock panel.

### 2 · System Settings refine  — `2-settings-refine/`
Uniform **monochrome line icons** for the System Settings sidebar sections
(replaces the mixed colorful set). A small **systemd path-watcher** re-tints them
to the active text color on every light↔dark switch (~400 ms) **and re-emits the
icon-changed signal** so the running taskbar/tray follow live, and flips the
theme's inherit order so non-overridden icons track the scheme (light-first in
light mode) instead of washing out. Also ships an optional **Kvantum whitespace
fork** (`NimbusRefined` + `NimbusRefinedDark`, not auto-selected) that adds
breathing room in classic Qt dialogs; if enabled, the watcher rides it light↔dark
too. Fully reversible: `2-settings-refine/revert.sh`.

Optional accent: **CoreyLavender** (`2-settings-refine/coreylavender/`) — a true
dark-lavender colour scheme rebuilt to pass WCAG AA/AAA (violet elevation ladder,
accent-coherent selection/focus, lightened semantics). Run it explicitly (it is
*not* part of the unconditional Layer 2 install, so it never hijacks your scheme):
`bash 2-settings-refine/coreylavender/install.sh` makes it available and pins it
as the WhiteSur-dark Look-and-Feel default so it survives login (Layer 1's toggle
already prefers it for dark mode when present); `--apply` switches the live
session now. Reversible via its `revert.sh` (restores `WhiteSurDark`).

> Scope note: the Settings sidebar *spacing/layout* is compiled Kirigami QML and
> is **not** reachable by any theming overlay — only the iconography and selection
> colors are. This layer does the reachable part well.

### 3 · KRunner finder  — `3-krunner-finder/`
- **Row styling** *(needs sudo)*: 48px icons, two-line rows (filename + greyed
  path), tighter gutter, fade/lift animations. Patches milou's QML and installs a
  **pacman hook** so it survives milou upgrades. Backs up originals; revert with
  `sudo bash 3-krunner-finder/row-tweak/revert.sh`.
- **Web / Claude / Hermes runner** *(no sudo)*: type and pause ~3 s for the
  auto-show rows, or prefix for instant — `s …`/`ddg …` (DuckDuckGo), `gh …`
  (GitHub), `w …` (Wikipedia), `yt …` (YouTube). `c …`/`ai …` → **Ask Claude**
  (opens a Claude Code session in konsole), shown only if the `claude` CLI is on
  `PATH`. `h …`/`hermes …` → **Ask Hermes** (opens `ollama run` on the local
  Hermes model in konsole — answers your query, then a REPL for follow-ups),
  shown only if `ollama` is present with a `hermes*` model pulled (Layer 6).
  Both stay hidden when their backend is missing.

### 4 · Login + lock screen  — `4-login-lock/`
Brings the two stock-Breeze surfaces into line so **login → lock → desktop** read
as one environment, by giving them the same Big Sur wallpaper:
- **Lock screen** *(no sudo)*: WhiteSur color scheme + Big Sur wallpaper.
- **SDDM login** *(sudo)*: overlays the breeze SDDM theme's background via a
  **non-destructive** `theme.conf.user` (the shipped theme is left untouched).

Run as your normal user — the lock part applies immediately and `sudo` prompts
once for the SDDM part. Revert: `4-login-lock/revert.sh`.

### 5 · System QoL  — `5-system-qol/`
General OS ergonomics — **not** desktop look. Each item is offered as its own
prompt (Enter = yes; `-y` accepts all), reversible, `sudo` for package installs:
- **`paccache.timer`** — weekly prune of old cached packages (needs `pacman-contrib`).
- **Flatpak + Flathub** — installs Flatpak and adds the Flathub remote for Discover.
- **Shell tooling (fish)** — `zoxide` (`z` smart-cd), **starship** prompt, and `fzf`
  keybindings (`Ctrl-R` history · `Ctrl-T` files w/ `bat` preview · `Alt-C` cd),
  dropped in as a guarded `~/.config/fish/conf.d/qol.fish` (no-op until the tools
  exist; doesn't duplicate the CachyOS fish defaults).
- **Timeshift** — installed in rsync mode (ext4-friendly); you pick the target +
  schedule once in `sudo timeshift-gtk`.

Revert: `5-system-qol/revert.sh` (`--purge` also removes the packages).

### 6 · Local AI  — `6-local-ai/`
A local LLM stack on the NVIDIA GPU — independent of the desktop look. Each item
is its own prompt (Enter = yes; `-y` accepts all), reversible, `sudo` only for the
package install:
- **`ollama-cuda`** — the runner + service, exposing a native API and an
  **OpenAI-compatible endpoint** at `http://localhost:11434/v1` (localhost only).
- **Hermes 4 14B** (`hermes4-14b`) — Q8_0, ~15.7 GB, fully GPU-resident on a 24 GB
  card; fast, with a 16k context. The snappy default.
- **Hermes 4.3 36B** (`hermes4.3-36b`) — Q4_K_M, ~22 GB; smarter but borderline on
  24 GB, so a few layers offload to CPU and the KV cache is kept at 8k.
- **Smoke test** — pings `/v1/chat/completions` and shows `ollama ps` (GPU split).
- **UI-audit agent** (`6-local-ai/ui-audit/`) — a grounded daily KDE-theming
  auditor for Hermes. Deploys the `kde-plasma-customization` skill (a
  deterministic state collector + a guardrail applier) and an opt-in daily cron
  job. The local LLM only *proposes* changes; the applier disposes — state-bound
  assertions, an allowlist that denies load-bearing keys, **earned** auto-apply
  (nothing applies until you approve a key once), backup+verify, `--revert`, and a
  deterministic report. Reversible via `ui-audit/revert.sh` (`--purge` also clears
  the audit runtime/ledger). An **opt-in usage signal** (`ui-audit-usage.py`, run
  network-isolated via `run-sandboxed.sh`) lets the report *focus* on the apps you
  actually use — app-level only (reuses KDE's KActivities scores; never reads file
  paths/URLs/titles/keystrokes/network), advisory ranking only (never changes what
  may be applied), 0600 + 30-day retention + `--forget`.

Models are defined by the two `Modelfile.*` (quant + context); edit and re-run
`ollama create` to retune. No sandbox yet — this just serves the models.
Revert: `6-local-ai/revert.sh` (`--purge` also removes the package + models +
`/var/lib/ollama` blobs).

### 7 · Apple-style notifications  — `7-notifications/`
Replaces Plasma's built-in notifications (a compiled C++ applet that can't be
restyled) with **[swaync](https://github.com/ErikReider/SwayNotificationCenter)**,
a fully CSS-themeable GTK4 daemon. `sudo` only for the package:
- **Frosted top-right toasts** — rounded ~16px cards with generous whitespace,
  light + dark variants that **ride the Meta+Ctrl+T toggle** via a `kdeglobals`
  path-watcher (same pattern as Layer 2's icon watcher).
- **Actionable** — app actions render as Apple-style pill buttons; inline reply
  shows for apps that advertise it (`7-notifications/demo/swaync-demo.sh` proves it).
- **Notification center** — frosted history panel with a **Do Not Disturb** toggle,
  bound to **Meta+N**.
- The handoff: a user-level `org.freedesktop.Notifications` D-Bus shadow points the
  name at swaync, and the tray Notifications entry is disabled. **Log out / back in**
  to guarantee swaync owns notifications.
- **Note — no real blur:** KWin doesn't blur layer-shell surfaces, so the "frost" is
  translucency (a soft `rgba` card over the wallpaper), not compositor backdrop blur.

Revert: `7-notifications/revert.sh` (`--purge` also removes the config + package);
restores Plasma's native notifications after a relogin.

### 8 · Dolphin Quick Look  — `8-dolphin-quicklook/`
macOS-style **Quick Look**: select a file in Dolphin and press **Space** to pop up a
preview; press **Space / Esc / Q** to dismiss it, **A / D** to step prev/next through
the folder, **Return** to open it. Previews images, video, audio, PDF and text via
**[kiview](https://github.com/Nyre221/kiview)** (a Qt/KDE quick-preview popup). Built
from **git master** via the bundled `PKGBUILD` (the tagged AUR `kiview` v1.1 lacks the
direct `kiview -s <file>` mode and instead grabs the selection over D-Bus, which glitches
from a service menu). Implemented with user-level files:
- A **Quick Look service menu** (`~/.local/share/kio/servicemenus/`, installed
  executable so KIO trusts it) adding a top-level right-click entry that runs
  `kiview -s` on the selected file (all file types).
- **Space bound to that action *inside Dolphin*** via its `ServiceMenuShortcutManager`
  (an `<ActionProperties>` entry in `~/.local/share/kxmlgui5/dolphin/dolphinui.rc`),
  so Space stays scoped to the file manager — untouched in every other app. Space is
  also cleared from Dolphin's built-in **Selection Mode** toggle to avoid a conflict
  (it stays on the toolbar button).
- Ships Dolphin 26.04's UI rc (gui version 48) as the base, since KXmlGui only honours
  a local rc that carries the full menu structure; if you've already customised Dolphin
  shortcuts, the two lines are merged into your file instead (backed up to `.orig`).
  On a different Dolphin version, assign Space once via *Configure Keyboard Shortcuts →
  Context Menu Actions → Quick Look* (it then sticks).
- **Borderless popup** — a KWin rule (`~/.config/kwinrulesrc`, matched on kiview's
  app-id `io.github.nyre221.kiview`) strips the titlebar so it reads as a transient
  Quick Look panel rather than an app window. The menu entry is labelled **"Quick Look
  (Space)"** to surface the shortcut.
- **Limitation:** the preview shows the file you launched it on and navigates *that*
  file's folder; it does **not** live-follow Dolphin's selection (no KDE tool does that).

Revert: `8-dolphin-quicklook/revert.sh` (restores `dolphinui.rc` + `kwinrulesrc` or
removes ours; `--purge` also uninstalls the kiview-git package).

### 9 · GPU UI effects  — `9-gpu-effects/`
GLSL shaders running **inside KWin's GPU compositing pipeline** (Plasma 6 already draws
the whole UI on the GPU — KWin composites through OpenGL/EGL, the shell via the QtQuick
scene graph; this layer just changes *which* shaders run). Three opt-in items:
- **Glass blur** (`kwin-effects-glass-git`, from the AUR; falls back to the archived
  `kwin-effects-forceblur`) — a maintained fork of KWin's blur that can **force-blur any
  window** (even opaque ones), draws **rounded corners**, blurs **docks/menus**
  (`BlurDocks`/`BlurMenus`), and adds refraction + brightness/saturation. It *replaces*
  Layer 1's stock blur (only one blur fork can run), so the install flips
  `blurEnabled→false` / `glassEnabled→true` and matches BlurStrength 15. Tune the rest in
  *Desktop Effects → Glass*.
  ⚠ **These forks ignore `qdbus6 …/KWin reconfigure`** — after editing their config you
  must re-apply via the `/Effects` D-Bus interface
  (`org.kde.kwin.Effects.reconfigureEffect glass`), or the change silently does nothing.
  The bundled skill (`.claude/skills/kwin-gpu-effects/`) and its inspector handle this.
- **Desktop shaders** (`kwin-effect-shaders`, built from source) — a single-pass GLSL
  post-process over the **final composited image**, a ReShade/vkBasalt equivalent for the
  whole desktop. Ships **CAS** (contrast-adaptive sharpening), FakeHDR, deband, tonemap,
  levels. Compiles against KWin's private headers (so it's **version-fragile** across KWin
  point releases). The visible shader pass stays **off** until you bind a toggle key
  (*Shortcuts → KWin → Toggle Shaders*); pick/tune shaders in
  `~/.local/share/kwin-effect-shaders_shaders/1_settings.glsl`.
- **Interactive aurora wallpaper** (`com.nimbus.aurora`, in `interactive-bg/`) — a custom
  Plasma 6 wallpaper plugin: an animated Big Sur gradient drawn by a GLSL fragment shader
  on the QtQuick scene graph. **Cursor-reactive** (a warm light blooms under the pointer,
  clicks pass through), **light/dark-aware** (follows the dock theme toggle automatically),
  with presets (Big Sur · Monterey · Graphite · Sunset · Nord) **+ a custom palette** and
  motion/vividness sliders — all in *Wallpaper → Configure*. Installs via
  `interactive-bg/apply.sh`, saving the prior wallpaper for a faithful revert. See
  `interactive-bg/README.md`.

**Wayland only** in practice — X11 disables compositing for fullscreen apps. All are pure
GLSL on the OpenGL backend (KWin's Vulkan backend is still experimental as of 2026).

Revert: `9-gpu-effects/revert.sh` restores Layer 1's stock blur, turns the shader pass
off, and switches the wallpaper back to whatever was active before the aurora; `--purge`
also removes the package, the built effect, the shader checkout, and the aurora plugin.

---

## Requirements
- Arch / CachyOS (`pacman`), **KDE Plasma 6**, **Wayland**
- Layer 1 installs (via sudo): `kvantum sassc optipng`
- Layer 3 runner deps: `python-dbus python-gobject` (web/Claude/Hermes runner)
- Internet (Layer 1 clones the WhiteSur themes + downloads the Inter font)

## Caveats (please read)
- **Version fragility:** Layer 3's QML patch and the refined icons target *this*
  Plasma/milou (6.6.x). On a very different version the milou patch may no-op
  (the pacman hook re-applies on update); the rest degrades gracefully.
- **Community themes:** built on [vinceliuice/WhiteSur](https://github.com/vinceliuice)
  plus locally-authored overlay files. Installed under `$HOME`. Provided **as-is,
  no warranty** — skim the scripts before trusting them.
- Test on a spare machine / VM before sharing widely.

## Reverting everything
```bash
bash revert.sh           # layers 2–9 fully; layer 1 prints manual steps
bash revert.sh --purge   # also deletes the installed overlay files
```

## Layout
```
install.sh  revert.sh  README.md
1-base/            nimbus-cachyos-macos.sh
2-settings-refine/ install.sh revert.sh icons/ kvantum/ systemd/ bin/
3-krunner-finder/  install.sh revert.sh row-tweak/ claude-runner/
4-login-lock/      install.sh revert.sh
5-system-qol/      install.sh revert.sh fish/
6-local-ai/        install.sh revert.sh Modelfile.hermes4-14b Modelfile.hermes4.3-36b
7-notifications/   install.sh revert.sh config.json style-{light,dark}.css bin/ systemd/ dbus/ demo/
8-dolphin-quicklook/ install.sh revert.sh nimbus-quicklook.desktop dolphinui.rc PKGBUILD
9-gpu-effects/     install.sh revert.sh
```
