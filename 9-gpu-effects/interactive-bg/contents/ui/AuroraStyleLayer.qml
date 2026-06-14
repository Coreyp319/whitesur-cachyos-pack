/*
 * AuroraStyleLayer — renders ONE aurora look (the real aurora.frag for styles 0..7,
 * FluidLayer for style 8). Extracted from AuroraPreview so the preview can hold two
 * of these and cross-dissolve between them when Style/Theme change. Carries no
 * framing of its own; the parent owns size, clock, reactTex and the border.
 */
import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: layer

    // shared from the parent
    property real    iTime: 0.0
    property variant reactTex

    // the look this layer shows
    property int   style: 0
    property int   theme: 0
    property real  dark: 1.0
    property real  intensity: 1.0
    property real  speed: 1.0
    property color color0: "#0d0f29"
    property color color1: "#1c2e73"
    property color color2: "#4552b8"
    property color color3: "#8f5cb8"
    property color color4: "#fa8c73"

    readonly property bool liquid: style === 8

    // styles 0..7 — single-pass aurora shader
    ShaderEffect {
        id: shader
        anchors.fill: parent
        visible: !layer.liquid
        fragmentShader: Qt.resolvedUrl("../shaders/aurora.frag.qsb")

        property variant reactTex: layer.reactTex
        property real     iTime: layer.iTime
        property vector2d iResolution: Qt.vector2d(Math.max(1, width), Math.max(1, height))
        property vector2d iMouse: Qt.vector2d(0.5, 0.5)
        property real     iMouseActive: 0.0
        property real     uSpeed: layer.speed
        property real     uInteractivity: 0.0
        property real     uDark: layer.dark
        property real     uIntensity: layer.intensity
        property int      uTheme: layer.theme
        property int      uStyle: layer.style
        property color    uColor0: layer.color0
        property color    uColor1: layer.color1
        property color    uColor2: layer.color2
        property color    uColor3: layer.color3
        property color    uColor4: layer.color4
        // reactivity off in the preview — declared so no uniform warns/garbages
        property real     uWinReact: 0.0
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
        property real     uMusicReact: 0.0
        property real     uBass: 0.0
        property real     uMid: 0.0
        property real     uTreble: 0.0
        property real     uLevel: 0.0
        property real     uBeat: 0.0
    }

    // style 8 — the real multi-pass fluid, same as the desktop
    Loader {
        anchors.fill: parent
        active: layer.liquid
        visible: active
        sourceComponent: layer.liquid ? fluidComponent : null
    }
    Component {
        id: fluidComponent
        FluidLayer {
            iTime: layer.iTime
            iMouse: Qt.vector2d(0.5, 0.5)
            iMouseActive: 0.0
            uTheme: layer.theme
            uDark: layer.dark
            uIntensity: layer.intensity
            uSpeed: layer.speed
            uColor0: layer.color0
            uColor1: layer.color1
            uColor2: layer.color2
            uColor3: layer.color3
            uColor4: layer.color4
            uMusicReact: 0.0; uBass: 0.0; uBeat: 0.0
            uWinReact: 0.0
            uActiveWin: Qt.vector4d(0, 0, 0, 0)
            uActiveVel: Qt.vector2d(0, 0)
            uActiveMove: 0.0
        }
    }
}
