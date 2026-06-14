/*
 * Nimbus Aurora — cursor-reactive wallpaper (Plasma 6).
 *
 * Renders contents/shaders/aurora.frag.qsb full-screen via a ShaderEffect on the
 * QtQuick scene graph. Time is frame-synced; the pointer is tracked hover-only so
 * desktop clicks / the right-click menu still pass through. Config lives in
 * contents/config/main.xml and is read through `root.configuration`.
 */
import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

WallpaperItem {
    id: root

    // --- config (with safe fallbacks) --------------------------------------
    readonly property real cfgSpeed:         configuration.Speed         ?? 1.0
    readonly property real cfgInteractivity: configuration.Interactivity ?? 0.0
    readonly property real cfgWinReact:      configuration.WindowReact   ?? 0.0
    readonly property real cfgMusicReact:    configuration.MusicReact    ?? 0.30
    readonly property real cfgIntensity:     configuration.Intensity     ?? 1.0
    readonly property int  cfgTheme:         configuration.Theme         ?? 0
    readonly property int  cfgStyle:         configuration.Style         ?? 0
    readonly property int  cfgAppearance:    configuration.Appearance    ?? 0  // 0 auto · 1 light · 2 dark

    // Light/dark. In auto mode we follow the Plasma colour scheme by polling its
    // canonical value (Kirigami.Theme does NOT track it in a wallpaper context).
    // The dock's light/dark toggle changes ColorScheme, so this picks it up.
    property bool schemeDark: true
    readonly property real uDark: cfgAppearance === 1 ? 0.0
                                : cfgAppearance === 2 ? 1.0
                                : (schemeDark ? 1.0 : 0.0)

    // Style 8 = Liquid: a real GPU fluid sim drawn by FluidLayer.qml instead of
    // the single-pass aurora shader. Pointer is shared with it via these raw
    // (un-eased, 0..1, y-down) properties so the fluid gets crisp force injection.
    readonly property bool liquid: cfgStyle === 8
    property real pMouseX: 0.5
    property real pMouseY: 0.5
    property real pMouseActive: 0.0

    P5Support.DataSource {
        id: schemeProbe
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            const s = (data["stdout"] || "").trim()
            if (s.length > 0) root.schemeDark = s.indexOf("Dark") !== -1
            disconnectSource(source)
        }
        function probe() { connectSource("kreadconfig6 --file kdeglobals --group General --key ColorScheme") }
    }
    // Reduce-motion: honour KDE's "Animation speed = Instant"
    // (AnimationDurationFactor 0) by freezing the drift. Same cheap poll cadence.
    property bool reduceMotion: false

    // --- surface yaw: a window-drag banks the Laserwave ground plane, lagging the
    //     drag and spring-winding back to neutral. Driven by the window bridge's
    //     active-window velocity (uActiveVel.x), through a damped SpringAnimation
    //     (the lag + overshoot + wind-back). Gated by reduce-motion.
    readonly property real yawDrive: reduceMotion ? 0.0
        : Math.max(-0.32, Math.min(0.32, -aurora.uActiveVel.x * 7.0))
    readonly property bool yawDragging: aurora.uActiveMove > 0.15
    property real yaw: yawDragging ? yawDrive : 0.0
    // asymmetric: quick to follow the drag (slight lag); ~6x slower, gentle wind-back to neutral
    Behavior on yaw { NumberAnimation { duration: root.yawDragging ? 110 : 2800
                                        easing.type: root.yawDragging ? Easing.OutCubic : Easing.OutSine } }

    // --- car steering: the Laserwave hero car orients toward the cursor in full
    //     3-D — yaw from pointer-X, pitch from pointer-Y — with a window-drag
    //     velocity impulse added on top, so it reacts to BOTH the pointer (always
    //     on, over the desktop) and dragged windows, every combination. Normalised
    //     to -1..1 per axis; 0 = neutral (the centre cell of the pose atlas). The
    //     target springs back to neutral when the pointer leaves/idles or under
    //     reduce-motion; carYaw/carPitch spring toward it so the car banks with
    //     weight and settles instead of snapping.
    readonly property real steerTargetX: reduceMotion ? 0.0 : Math.max(-1.0, Math.min(1.0,
          (root.pMouseActive > 0.01 ? (root.pMouseX - 0.5) * 2.0 : 0.0)
        + (root.yawDragging ? -aurora.uActiveVel.x * 6.0 : 0.0)))
    readonly property real steerTargetY: reduceMotion ? 0.0 : Math.max(-1.0, Math.min(1.0,
          (root.pMouseActive > 0.01 ? (0.5 - root.pMouseY) * 2.0 : 0.0)
        + (root.yawDragging ? -aurora.uActiveVel.y * 6.0 : 0.0)))
    property real carYaw:   0.0
    property real carPitch: 0.0
    readonly property bool carSteering: (pMouseActive > 0.01) || yawDragging
    // Frame-driven exponential smoothing — a low-pass that DEBOUNCES cursor jitter
    // into one continuous glide (no per-event re-targeting steps, which read as
    // micro-stutter when sweeping across). Snappy time-constant while steering; a
    // long, gentle wind-back to neutral (the "coast over a quarter-mile of road"
    // feel) once the pointer leaves. Snaps within epsilon so a settled car stops
    // repainting. Gated to the Laserwave style (only the car uses it).
    Connections {
        target: clock
        enabled: root.cfgStyle === 5
        function onTriggered() {
            var dt  = clock.frameTime
            if (!(dt > 0.0)) dt = 0.016                      // guard a 0/NaN first frame (~60fps)
            dt = Math.min(dt, 0.05)                          // clamp against frame hitches
            var tau = root.carSteering ? 0.11 : 1.9          // smaller = snappier; large = long coast-back
            var k   = 1.0 - Math.exp(-dt / tau)
            var tx  = root.steerTargetX, ty = root.steerTargetY
            root.carYaw   = (Math.abs(tx - root.carYaw)   < 0.0006) ? tx : root.carYaw   + (tx - root.carYaw)   * k
            root.carPitch = (Math.abs(ty - root.carPitch) < 0.0006) ? ty : root.carPitch + (ty - root.carPitch) * k
        }
    }
    P5Support.DataSource {
        id: motionProbe
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            const s = (data["stdout"] || "").trim()
            if (s.length > 0) root.reduceMotion = parseFloat(s) === 0.0
            disconnectSource(source)
        }
        function probe() { connectSource("kreadconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor") }
    }
    // 1 s so the dock light/dark toggle is picked up quickly (was 2 s, which read
    // as "the toggle does nothing" — there's an extra 700 ms uDark ease on top).
    Timer { interval: 1000; repeat: true; running: true; triggeredOnStart: true
            onTriggered: { schemeProbe.probe(); motionProbe.probe() } }

    // --- window reactivity -------------------------------------------------
    // The KWin script + bridge daemon write live window geometry to a state file
    // in the runtime dir (see interactive-bg/README.md). We poll it here, map the
    // global-pixel rects to THIS screen's 0..1 space, and feed the shader. Costs
    // nothing when cfgWinReact == 0 (the timer stops, the shader skips the work).
    property string statePath: ""        // file:// URL, resolved once via $XDG_RUNTIME_DIR
    property string audioPath: ""        // file:// URL for the music bridge's state file
    property real   _velX: 0.0           // EMA-smoothed active-window velocity (p-space)
    property real   _velY: 0.0

    P5Support.DataSource {
        id: runtimeProbe
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            const dir = (data["stdout"] || "").trim()
            if (dir.length > 0) {
                root.statePath = "file://" + dir + "/nimbus-aurora/windows.json"
                root.audioPath = "file://" + dir + "/nimbus-aurora/audio.json"
            }
            disconnectSource(source)
        }
        Component.onCompleted: connectSource("printf %s \"$XDG_RUNTIME_DIR\"")
    }

    // Reads the window state file via the executable engine (a `cat`). This is the
    // ONLY mechanism we use: XHR on a file:// URL never reaches DONE in this Plasma
    // build, so it silently delivered nothing. The exec engine is the same path the
    // scheme/motion probes use and is reliable. connectSource runs the command,
    // onNewData disconnects so the next read re-runs it.
    P5Support.DataSource {
        id: winFileProbe
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            const txt = (data["stdout"] || "")
            disconnectSource(source)
            if (txt.length > 0) root.applyWindows(txt)
        }
        function read(path) { connectSource("cat " + path + " 2>/dev/null") }
    }

    function pollWindows() {
        if (root.statePath.length === 0 || root.cfgWinReact <= 0.0) return
        winFileProbe.read(root.statePath.substring(7))   // statePath is "file://…" — strip the scheme for `cat`
    }

    // Map global-pixel window rects onto this wallpaper's screen and push to the shader.
    function applyWindows(text) {
        var d
        try { d = JSON.parse(text) } catch (e) { return }   // ignore a half-written read
        var sx = Screen.virtualX, sy = Screen.virtualY
        var sw = Screen.width,    sh = Screen.height
        if (sw <= 0 || sh <= 0) return

        var zero = Qt.vector4d(0, 0, 0, 0)
        var slots = [zero, zero, zero, zero, zero, zero]
        var n = 0
        var wins = d.wins || []
        for (var i = 0; i < wins.length && n < 6; i++) {
            var w = wins[i]
            var nx = (w.x - sx) / sw, ny = (w.y - sy) / sh
            var nw = w.w / sw,        nh = w.h / sh
            if (nx + nw <= 0 || nx >= 1 || ny + nh <= 0 || ny >= 1) continue  // not on this screen
            slots[n++] = Qt.vector4d(nx, ny, nw, nh)
        }
        aurora.uWin0 = slots[0]; aurora.uWin1 = slots[1]; aurora.uWin2 = slots[2]
        aurora.uWin3 = slots[3]; aurora.uWin4 = slots[4]; aurora.uWin5 = slots[5]
        aurora.uWinCount = n

        if (d.move) {
            aurora.uActiveWin = Qt.vector4d((d.move.x - sx) / sw, (d.move.y - sy) / sh,
                                            d.move.w / sw, d.move.h / sh)
            // velocity in the shader's aspect-corrected p-space (1 unit = screen
            // HEIGHT on both axes), so speed and direction are isotropic — a
            // diagonal drag wakes like a horizontal one of equal pixel speed.
            var rvx = d.move.vx / sh, rvy = d.move.vy / sh
            // EMA-smooth it: the bridge's velocity is a raw finite difference with a
            // jittery per-event dt, so unsmoothed it spiked frame to frame and made
            // the wake brightness FLASH during drags. Smoothing de-flickers it.
            root._velX = 0.35 * rvx + 0.65 * root._velX
            root._velY = 0.35 * rvy + 0.65 * root._velY
            aurora.uActiveVel = Qt.vector2d(root._velX, root._velY)
            aurora.uActiveMove = 1.0
        } else {
            // keep the LAST velocity and let the eased uActiveMove fade the whole
            // wake (ring + trail + flow-shove) out together. Zeroing vel here
            // snapped the directional trail off the instant you released, leaving
            // only the symmetric ring — the motion lost its sense of momentum.
            aurora.uActiveMove = 0.0
        }
    }

    Timer {
        interval: 33; repeat: true            // ~30 Hz; the shader's own motion fills gaps
        running: root.cfgWinReact > 0.0 && root.statePath.length > 0
        onTriggered: root.pollWindows()
    }

    // --- music reactivity --------------------------------------------------
    // The audio bridge (pw-cat → FFT, a systemd --user service) writes
    // bass/mid/treble/level/beat to audio.json in the runtime dir. Read via the
    // executable engine, same as the window state (file:// XHR is unusable here).
    P5Support.DataSource {
        id: audioFileProbe
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            const txt = (data["stdout"] || "")
            disconnectSource(source)
            if (txt.length > 0) root.applyAudio(txt)
        }
        function read(path) { connectSource("cat " + path + " 2>/dev/null") }
    }

    function pollAudio() {
        if (root.audioPath.length === 0 || root.cfgMusicReact <= 0.0) return
        audioFileProbe.read(root.audioPath.substring(7))   // audioPath is "file://…" — strip the scheme for `cat`
    }

    function applyAudio(text) {
        var a
        try { a = JSON.parse(text) } catch (e) { return }
        aurora.uBass   = a.bass   ?? 0.0
        aurora.uMid    = a.mid    ?? 0.0
        aurora.uTreble = a.treble ?? 0.0
        aurora.uLevel  = a.level  ?? 0.0
        aurora.uBeat   = a.beat   ?? 0.0     // snappy: not eased, so the ripple stays crisp
    }

    Timer {
        interval: 33; repeat: true            // ~30 Hz, matches the bridge's write cadence
        running: root.cfgMusicReact > 0.0 && root.audioPath.length > 0
        onTriggered: root.pollAudio()
    }

    // frame-synced clock for iTime
    FrameAnimation {
        id: clock
        running: true
    }

    // sceneRoot = everything the bloom pass captures: the aurora field + the hero.
    // It's hidden from direct rendering (sceneSrc hideSource) and drawn — bloomed —
    // by bloomComposite below.
    Item {
    id: sceneRoot
    anchors.fill: parent

    ShaderEffect {
        id: aurora
        anchors.fill: parent
        visible: !root.liquid          // the Liquid style renders via FluidLayer instead
        // re-evaluated every frame via the iTime binding -> continuous repaint
        fragmentShader: Qt.resolvedUrl("../shaders/aurora.frag.qsb")

        // persistent reactive field (cursor trails / music ripples / window wakes)
        property variant reactTex: reactBuf

        property real     iTime: clock.elapsedTime
        property vector2d iResolution: Qt.vector2d(width, height)
        // Speed/Vividness ease when nudged in the config (matching the uDark ease),
        // so a slider change glides instead of snapping. Gated by reduceMotion so
        // KDE "Animation = Instant" still applies instantly. Theme/Style stay a hard
        // cut (rare, "set once" choices — a cross-dissolve there isn't worth 2× cost).
        property real     uSpeed: root.reduceMotion ? 0.0 : root.cfgSpeed
        Behavior on uSpeed { enabled: !root.reduceMotion; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        property real     uInteractivity: root.cfgInteractivity
        property real     uIntensity: root.cfgIntensity
        Behavior on uIntensity { enabled: !root.reduceMotion; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
        property int      uTheme: root.cfgTheme
        property int      uStyle: root.cfgStyle
        // eased so the dock light/dark toggle cross-fades instead of snapping
        property real     uDark: root.uDark
        Behavior on uDark { NumberAnimation { duration: 700; easing.type: Easing.InOutCubic } }

        // custom palette (consumed by the shader only when uTheme == 3). Eased so
        // editing a stop recolours smoothly instead of jumping (same reduceMotion gate).
        property color    uColor0: root.configuration.Color0 ?? "#0d0f29"
        property color    uColor1: root.configuration.Color1 ?? "#1c2e73"
        property color    uColor2: root.configuration.Color2 ?? "#4552b8"
        property color    uColor3: root.configuration.Color3 ?? "#8f5cb8"
        property color    uColor4: root.configuration.Color4 ?? "#fa8c73"
        Behavior on uColor0 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
        Behavior on uColor1 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
        Behavior on uColor2 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
        Behavior on uColor3 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
        Behavior on uColor4 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }

        // window reactivity (fed by pollWindows/applyWindows above). Rects are
        // normalised to this screen; the wake fades via the eased uActiveMove so
        // letting go of a window doesn't snap the glow off.
        property real     uWinReact: root.cfgWinReact
        property int      uWinCount: 0
        property vector4d uWin0: Qt.vector4d(0, 0, 0, 0)
        property vector4d uWin1: Qt.vector4d(0, 0, 0, 0)
        property vector4d uWin2: Qt.vector4d(0, 0, 0, 0)
        property vector4d uWin3: Qt.vector4d(0, 0, 0, 0)
        property vector4d uWin4: Qt.vector4d(0, 0, 0, 0)
        property vector4d uWin5: Qt.vector4d(0, 0, 0, 0)
        property vector4d uActiveWin: Qt.vector4d(0, 0, 0, 0)
        property vector2d uActiveVel: Qt.vector2d(0, 0)
        property real     uActiveMove: 0.0
        Behavior on uActiveMove { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

        // music reactivity (fed by pollAudio/applyAudio). Bands eased so they
        // glide; uBeat is left un-eased so the ripple fires crisply.
        property real     uMusicReact: root.cfgMusicReact
        property real     uBass: 0.0
        property real     uMid: 0.0
        property real     uTreble: 0.0
        property real     uLevel: 0.0
        property real     uBeat: 0.0
        // window-drag surface yaw (eased + spring-back) + a gentle bank from the
        // car's steer, so the neon ground plane leans WITH the car as it turns.
        property real     uYaw: root.yaw + root.carYaw * 0.08
        // the Laserwave ground morphs into rolling hills; the car's pitch (cursor-Y)
        // deepens them, so nosing up reads as cresting. uHill = base strength.
        property real     uPitch: root.carPitch
        property real     uHill: 1.0
        Behavior on uBass   { NumberAnimation { duration: 90;  easing.type: Easing.OutQuad } }
        Behavior on uMid    { NumberAnimation { duration: 90;  easing.type: Easing.OutQuad } }
        Behavior on uTreble { NumberAnimation { duration: 70;  easing.type: Easing.OutQuad } }
        Behavior on uLevel  { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

        // pointer, eased component-wise so motion feels liquid, not twitchy
        property real     iMouseX: 0.5
        property real     iMouseY: 0.5
        property vector2d iMouse: Qt.vector2d(iMouseX, iMouseY)
        property real     iMouseActive: 0.0
        Behavior on iMouseX      { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
        Behavior on iMouseY      { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
        Behavior on iMouseActive { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
    }

    // Blender-authored hero (turntable sprite) — a neon "core" composited over
    // the neon styles as a hovering, slowly-rotating billboard. Inside sceneRoot
    // so the bloom pass glows it too. Shown only on Laserwave (5) + Datascape (7);
    // beat-pulses, bobs gently (frozen under reduce-motion), and fades on/off.
    Item {
        id: heroGroup
        readonly property bool show: root.cfgStyle === 7   // Datascape; Laserwave has its own assets
        visible: opacity > 0.01
        opacity: show ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.InOutCubic } }
        transformOrigin: Item.Center

        readonly property real heroSize: Math.min(root.width, root.height) * 0.42
        width: heroSize; height: heroSize
        x: (root.width - width) / 2
        property real phase: 0
        NumberAnimation on phase {
            running: heroGroup.show && !root.reduceMotion
            from: 0; to: 2 * Math.PI; duration: 6000; loops: Animation.Infinite
        }
        y: root.height * (root.cfgStyle === 5 ? 0.10 : 0.14) + root.height * 0.012 * Math.sin(phase)
        scale: 1.0 + 0.10 * aurora.uBeat
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

        AnimatedSprite {
            id: heroSprite
            anchors.fill: parent
            source: Qt.resolvedUrl("../assets/hero_core.png")
            frameCount: 16; frameWidth: 384; frameHeight: 384
            frameRate: 5
            running: heroGroup.show && !root.reduceMotion
            loops: AnimatedSprite.Infinite
            interpolate: false
            smooth: true
        }
    }
    }  // end sceneRoot

    // --- bloom: capture sceneRoot (aurora + hero) and add a soft neon glow -----
    // The biggest 'rendered vs flat' lever. sceneSrc captures the hidden scene as a
    // texture (same provider pattern as reactBuf); bloomComposite adds a bright-pass
    // glow over it. Lighter in light mode; paused + hidden on the Liquid style.
    ShaderEffectSource {
        id: sceneSrc
        sourceItem: sceneRoot
        hideSource: true
        live: !root.liquid
    }
    ShaderEffect {
        id: bloomComposite
        anchors.fill: parent
        visible: !root.liquid
        property variant src: sceneSrc
        property vector2d iResolution: Qt.vector2d(width, height)
        // Laserwave (5) has a big bright sun + composited assets, so it blooms gently;
        // the dark neon Datascape/others can take a stronger glow. Lighter in light mode.
        property real uThreshold: root.cfgStyle === 5 ? 0.66 : 0.50
        property real uIntensity: (root.cfgStyle === 5 ? 0.38 : 0.70)
                                + (root.cfgStyle === 5 ? 0.22 : 0.60) * root.uDark
        property real uRadius: Math.max(8.0, height * 0.045)
        fragmentShader: Qt.resolvedUrl("../shaders/bloom.frag.qsb")
    }

    // --- Laserwave hero: the OutRun car, full-3-D reactive (ON TOP of the bloom) -
    // A real car (Sketchfab "Cheetah '84" by DanielZhabotinsky, CC-BY) baked HDRI-lit
    // in Blender into a 9×5 YAW×PITCH pose ATLAS (car_grid.png). frameselect.frag
    // bilinearly blends the four neighbouring cells for the car's continuous, spring-
    // eased orientation (root.carYaw / root.carPitch) so it genuinely TURNS and
    // PITCHES in 3-D — tracking the cursor and reacting to window-drags, every
    // combination — instead of snapping between frames. A faint mirrored copy below
    // reads as a wet-grid reflection that grounds it.
    // OUTSIDE sceneRoot — drawn over the bloom, NOT captured by it (a child driven by
    // these uniforms does not update through the ShaderEffectSource). Style 5 only;
    // HDRI-lit, so it needs no procedural bloom.
    Item {
        id: laserwaveLayer
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: root.cfgStyle === 5 ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.InOutCubic } }

        readonly property int  cols: 9        // yaw columns in the atlas (left↔right)
        readonly property int  rows: 5        // pitch rows (nose up↕down)
        // continuous cell coords from the eased orientation (-1..1 per axis):
        //   carYaw  +1 (cursor right) -> last column ; -1 -> first
        //   carPitch +1 (cursor up)   -> top row (nose-up pose) ; -1 -> bottom row
        readonly property real cellCol: (root.carYaw * 0.5 + 0.5) * (cols - 1)
        readonly property real cellRow: (0.5 - root.carPitch * 0.5) * (rows - 1)
        readonly property real carW: root.width * 0.21
        readonly property real carH: carW * 254.0 / 429.0     // atlas cell aspect (level rear chase view + glow pad)
        readonly property real driftY: root.reduceMotion ? 0.0 : Math.sin(clock.elapsedTime * 0.6) * 0.005 * root.height
        readonly property real carX: root.width * 0.50 - carW / 2 + root.carYaw * root.width * 0.05
        readonly property real carY: root.height * 0.62 - carH / 2 + driftY - root.carPitch * root.height * 0.018

        Image { id: carSheet; source: Qt.resolvedUrl("../assets/laserwave/car_grid.png"); visible: false }

        // neon contact-glow pool under the car (replaces the baked Blender plane):
        // theme-coloured, beat-pulsed, follows the car's lateral slide. Drawn first,
        // so the reflection and car sit on top of it.
        ShaderEffect {
            id: carUnderglow
            width: laserwaveLayer.carW * 1.15
            height: laserwaveLayer.carH * 0.60
            x: laserwaveLayer.carX + laserwaveLayer.carW / 2 - width / 2
            y: laserwaveLayer.carY + laserwaveLayer.carH * 0.55
            property color uColorA: "#22e0ff"     // cyan core — complements the pink tail-lights & red body
            property color uColorB: "#5a2a9e"     // violet rim
            property real  uIntensity: 0.42 + 0.30 * aurora.uBeat
            fragmentShader: Qt.resolvedUrl("../shaders/underglow.frag.qsb")
        }

        // wet-grid reflection: a foreshortened, mirrored, dim copy under the wheels.
        ShaderEffect {
            id: carReflection
            width: laserwaveLayer.carW; height: laserwaveLayer.carH
            x: laserwaveLayer.carX
            y: laserwaveLayer.carY + height * 0.88
            opacity: 0.20
            transform: Scale { origin.x: carReflection.width / 2; origin.y: 0; yScale: -0.82 }
            property variant src: carSheet
            property real uCol: laserwaveLayer.cellCol
            property real uRow: laserwaveLayer.cellRow
            property real uCols: laserwaveLayer.cols
            property real uRows: laserwaveLayer.rows
            property real uBlend: 1.0
            fragmentShader: Qt.resolvedUrl("../shaders/frameselect.frag.qsb")
        }

        // the car — bilinear cell blend gives a smooth 3-D turn/pitch; a subtle
        // bank-into-the-steer roll and a beat-synced pop add life.
        ShaderEffect {
            id: heroCar
            width: laserwaveLayer.carW; height: laserwaveLayer.carH
            x: laserwaveLayer.carX; y: laserwaveLayer.carY
            transformOrigin: Item.Center
            rotation: root.carYaw * 3.0
            scale: 1.0 + 0.05 * aurora.uBeat
            property variant src: carSheet
            property real uCol: laserwaveLayer.cellCol
            property real uRow: laserwaveLayer.cellRow
            property real uCols: laserwaveLayer.cols
            property real uRows: laserwaveLayer.rows
            property real uBlend: 1.0
            fragmentShader: Qt.resolvedUrl("../shaders/frameselect.frag.qsb")
        }
    }

    // --- reactive feedback field ------------------------------------------
    // Persistent excitation (cursor trails / music ripples / window wakes) that
    // aurora.frag samples for glow + flow displacement. Runs at a capped res; it
    // is paused for the Liquid style (which has its own forces, and hides aurora).
    readonly property int reactW: Math.max(16, Math.round(Math.min(width, 960)))
    readonly property int reactH: Math.max(16, Math.round(reactW * (height / Math.max(1, width))))
    ShaderEffect {
        id: reactStep
        width: root.reactW; height: root.reactH
        blending: false
        property vector2d iResolution: Qt.vector2d(root.reactW, root.reactH)
        property real     iTime: clock.elapsedTime
        property vector2d iMouse: Qt.vector2d(root.pMouseX, root.pMouseY)
        property real     iMouseActive: root.pMouseActive
        property real     uInteractivity: root.cfgInteractivity
        property real     uWinReact: aurora.uWinReact
        property vector4d uActiveWin: aurora.uActiveWin
        property vector2d uActiveVel: aurora.uActiveVel
        property real     uActiveMove: aurora.uActiveMove
        property real     uMusicReact: aurora.uMusicReact
        property real     uBass: aurora.uBass
        property real     uLevel: aurora.uLevel
        property real     uBeat: aurora.uBeat
        property real     decay: 0.975   // higher = longer-lingering trails/ripples
        property real     drift: 0.6
        property variant  prevTex: reactBuf
        fragmentShader: Qt.resolvedUrl("../shaders/react.frag.qsb")
    }
    ShaderEffectSource {
        id: reactBuf
        sourceItem: reactStep
        live: !root.liquid; recursive: true; hideSource: true
        format: ShaderEffectSource.RGBA16F
        textureSize: Qt.size(root.reactW, root.reactH)
        wrapMode: ShaderEffectSource.ClampToEdge
    }

    // Liquid style: a real GPU fluid (FluidLayer.qml) instead of the aurora
    // shader. Only instantiated while selected, so other styles cost nothing.
    Loader {
        id: fluidLoader
        anchors.fill: parent
        active: root.liquid
        visible: active
        sourceComponent: fluidComponent
    }
    Component {
        id: fluidComponent
        FluidLayer {
            iTime: clock.elapsedTime
            iMouse: Qt.vector2d(root.pMouseX, root.pMouseY)
            iMouseActive: root.pMouseActive
            uTheme: root.cfgTheme
            uDark: root.uDark
            uIntensity: root.cfgIntensity
            uSpeed: root.reduceMotion ? 0.0 : root.cfgSpeed
            uColor0: root.configuration.Color0 ?? "#0d0f29"
            uColor1: root.configuration.Color1 ?? "#1c2e73"
            uColor2: root.configuration.Color2 ?? "#4552b8"
            uColor3: root.configuration.Color3 ?? "#8f5cb8"
            uColor4: root.configuration.Color4 ?? "#fa8c73"
            // ease Vividness/Speed/colours on the Liquid style too (reduceMotion-gated),
            // so the tween matches the single-pass styles instead of snapping here.
            Behavior on uIntensity { enabled: !root.reduceMotion; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            Behavior on uSpeed     { enabled: !root.reduceMotion; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            Behavior on uColor0 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
            Behavior on uColor1 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
            Behavior on uColor2 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
            Behavior on uColor3 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
            Behavior on uColor4 { enabled: !root.reduceMotion; ColorAnimation { duration: 500; easing.type: Easing.InOutCubic } }
            // music + window reactivity (aurora holds the live bridge values even
            // while hidden — its polling timers run regardless of style)
            uMusicReact: aurora.uMusicReact
            uBass: aurora.uBass
            uBeat: aurora.uBeat
            uWinReact: aurora.uWinReact
            uActiveWin: aurora.uActiveWin
            uActiveVel: aurora.uActiveVel
            uActiveMove: aurora.uActiveMove
        }
    }

    // hover-only tracking: NoButton => presses fall through to the desktop
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        onPositionChanged: (m) => {
            aurora.iMouseX = m.x / width
            aurora.iMouseY = m.y / height
            aurora.iMouseActive = 1.0
            root.pMouseX = m.x / width
            root.pMouseY = m.y / height
            root.pMouseActive = 1.0
        }
        onEntered: { aurora.iMouseActive = 1.0; root.pMouseActive = 1.0 }
        onExited:  { aurora.iMouseActive = 0.0; root.pMouseActive = 0.0 }
    }
}
