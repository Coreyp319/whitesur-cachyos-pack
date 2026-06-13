/*
 * Nimbus Aurora — Liquid style.
 *
 * A real GPU Eulerian fluid (stable fluids) rendered entirely on the QtQuick
 * scene graph via RGBA16F float feedback buffers — no KWin, no compute, no
 * external process. Three recursive ShaderEffectSource buffers hold the velocity,
 * pressure and dye fields; each is updated once per frame by its ShaderEffect:
 *
 *   velStep : advect velocity + forces + (amortized) pressure projection -> velBuf
 *   prsStep : one Jacobi pressure iteration, warm-started               -> prsBuf
 *   dyeStep : advect + inject coloured dye                              -> dyeBuf
 *   display : style the dye as glowing ink over the themed backdrop     -> screen
 *
 * Float buffers (RGBA16F) are what make this a real sim rather than the faked
 * single-pass "Ink in water" look — velocity/pressure need signed, fine-grained
 * values that 8-bit buffers would band and drift away.
 *
 * Sim runs at a capped resolution and the display upsamples (bilinear) so it is
 * cheap even on a 4K screen.
 */
import QtQuick

Item {
    id: fluid

    // --- inputs (set by the Loader in main.qml) ----------------------------
    property real     iTime: 0.0
    property vector2d iMouse: Qt.vector2d(0.5, 0.5)   // 0..1, y-down
    property real     iMouseActive: 0.0
    property int      uTheme: 0
    property real     uDark: 1.0
    property real     uIntensity: 1.0
    property real     uSpeed: 1.0
    property color    uColor0: "#0d0f29"
    property color    uColor1: "#1c2e73"
    property color    uColor2: "#4552b8"
    property color    uColor3: "#8f5cb8"
    property color    uColor4: "#fa8c73"
    // music + window reactivity (fed from main.qml's live bridge values)
    property real     uMusicReact: 0.0
    property real     uBass: 0.0
    property real     uBeat: 0.0
    property real     uWinReact: 0.0
    property vector4d uActiveWin: Qt.vector4d(0, 0, 0, 0)
    property vector2d uActiveVel: Qt.vector2d(0, 0)
    property real     uActiveMove: 0.0

    // --- simulation resolution (cap width; keep aspect) --------------------
    readonly property real simScale: Math.min(1.0, 1280.0 / Math.max(1.0, width))
    readonly property int  simW: Math.max(16, Math.round(width  * simScale))
    readonly property int  simH: Math.max(16, Math.round(height * simScale))
    readonly property size simSize: Qt.size(simW, simH)
    readonly property vector2d simRes: Qt.vector2d(simW, simH)

    // cursor velocity in texels/step, refreshed each frame from iMouse deltas
    property vector2d _mousePrev: Qt.vector2d(0.5, 0.5)
    property vector2d iMouseVel: Qt.vector2d(0.0, 0.0)
    onITimeChanged: {
        iMouseVel = Qt.vector2d((iMouse.x - _mousePrev.x) * simW,
                                (iMouse.y - _mousePrev.y) * simH)
        _mousePrev = iMouse
    }

    // --- VELOCITY field ----------------------------------------------------
    ShaderEffect {
        id: velStep
        width: fluid.simW; height: fluid.simH
        blending: false
        property vector2d iResolution: fluid.simRes
        property real     iTime: fluid.iTime
        property vector2d iMouse: fluid.iMouse
        property vector2d iMouseVel: fluid.iMouseVel
        property real     dt: 1.0
        property real     velDiss: 0.997
        property real     forceScale: 0.55 * fluid.uSpeed
        property real     splatRadius: 0.06
        property real     uMusicReact: fluid.uMusicReact
        property real     uBass: fluid.uBass
        property real     uBeat: fluid.uBeat
        property real     uWinReact: fluid.uWinReact
        property vector4d uActiveWin: fluid.uActiveWin
        property vector2d uActiveVel: fluid.uActiveVel
        property real     uActiveMove: fluid.uActiveMove
        property variant  velTex: velBuf
        property variant  prsTex: prsBuf
        fragmentShader: Qt.resolvedUrl("../shaders/fluid_velocity.frag.qsb")
    }
    ShaderEffectSource {
        id: velBuf
        sourceItem: velStep
        live: true; recursive: true; hideSource: true
        format: ShaderEffectSource.RGBA16F
        textureSize: fluid.simSize
        wrapMode: ShaderEffectSource.ClampToEdge
    }

    // --- PRESSURE field (3 Jacobi iterations/frame, warm-started) ----------
    // prsBuf is the persistent (recursive) pressure: it warm-starts iteration 1
    // and receives iteration 3, so the solve keeps converging across frames.
    // p1/p2 are fresh intermediates. More iterations = crisper, less "puffy".
    ShaderEffect {
        id: prsStep1
        width: fluid.simW; height: fluid.simH
        blending: false
        property vector2d iResolution: fluid.simRes
        property variant  velTex: velBuf
        property variant  prsTex: prsBuf
        fragmentShader: Qt.resolvedUrl("../shaders/fluid_pressure.frag.qsb")
    }
    ShaderEffectSource {
        id: prsP1
        sourceItem: prsStep1; live: true; hideSource: true
        format: ShaderEffectSource.RGBA16F; textureSize: fluid.simSize
        wrapMode: ShaderEffectSource.ClampToEdge
    }
    ShaderEffect {
        id: prsStep2
        width: fluid.simW; height: fluid.simH
        blending: false
        property vector2d iResolution: fluid.simRes
        property variant  velTex: velBuf
        property variant  prsTex: prsP1
        fragmentShader: Qt.resolvedUrl("../shaders/fluid_pressure.frag.qsb")
    }
    ShaderEffectSource {
        id: prsP2
        sourceItem: prsStep2; live: true; hideSource: true
        format: ShaderEffectSource.RGBA16F; textureSize: fluid.simSize
        wrapMode: ShaderEffectSource.ClampToEdge
    }
    ShaderEffect {
        id: prsStep3
        width: fluid.simW; height: fluid.simH
        blending: false
        property vector2d iResolution: fluid.simRes
        property variant  velTex: velBuf
        property variant  prsTex: prsP2
        fragmentShader: Qt.resolvedUrl("../shaders/fluid_pressure.frag.qsb")
    }
    ShaderEffectSource {
        id: prsBuf
        sourceItem: prsStep3
        live: true; recursive: true; hideSource: true
        format: ShaderEffectSource.RGBA16F
        textureSize: fluid.simSize
        wrapMode: ShaderEffectSource.ClampToEdge
    }

    // --- DYE field ---------------------------------------------------------
    ShaderEffect {
        id: dyeStep
        width: fluid.simW; height: fluid.simH
        blending: false
        property vector2d iResolution: fluid.simRes
        property real     iTime: fluid.iTime
        property vector2d iMouse: fluid.iMouse
        property vector2d iMouseVel: fluid.iMouseVel
        property real     dt: 1.0
        property real     dyeDiss: 0.986
        property real     splatRadius: 0.06
        property color    uColor1: fluid.uColor1
        property color    uColor2: fluid.uColor2
        property color    uColor3: fluid.uColor3
        property real     uMusicReact: fluid.uMusicReact
        property real     uBeat: fluid.uBeat
        property real     uWinReact: fluid.uWinReact
        property vector4d uActiveWin: fluid.uActiveWin
        property vector2d uActiveVel: fluid.uActiveVel
        property real     uActiveMove: fluid.uActiveMove
        property variant  dyeTex: dyeBuf
        property variant  velTex: velBuf
        fragmentShader: Qt.resolvedUrl("../shaders/fluid_dye.frag.qsb")
    }
    ShaderEffectSource {
        id: dyeBuf
        sourceItem: dyeStep
        live: true; recursive: true; hideSource: true
        format: ShaderEffectSource.RGBA16F
        textureSize: fluid.simSize
        wrapMode: ShaderEffectSource.ClampToEdge
    }

    // --- DISPLAY (upsampled to the full wallpaper) -------------------------
    ShaderEffect {
        id: display
        anchors.fill: parent
        property vector2d iResolution: fluid.simRes
        property real     uDark: fluid.uDark
        property real     uIntensity: fluid.uIntensity
        property int      uTheme: fluid.uTheme
        property color    uColor0: fluid.uColor0
        property color    uColor1: fluid.uColor1
        property color    uColor2: fluid.uColor2
        property color    uColor3: fluid.uColor3
        property color    uColor4: fluid.uColor4
        property variant  dyeTex: dyeBuf
        property variant  velTex: velBuf
        fragmentShader: Qt.resolvedUrl("../shaders/fluid_display.frag.qsb")
    }
}
