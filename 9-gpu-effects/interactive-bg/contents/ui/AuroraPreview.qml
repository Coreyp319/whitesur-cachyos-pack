/*
 * AuroraPreview — a live, frame-synced thumbnail of the currently selected look,
 * for the wallpaper config dialog. Renders the real aurora.frag / FluidLayer via
 * AuroraStyleLayer, so it's the actual look, not an approximation.
 *
 * Tweening — discrete swaps (Style, Theme) CROSS-DISSOLVE. The mechanism is
 * deliberately state-machine-free for robustness: the bottom layer (`layerCur`) is
 * BOUND to the current target, so it is ALWAYS the latest look — no imperative
 * "which layer is committed" bookkeeping that can desync when clicks land during a
 * fade. On change, the *previous* look is painted on top (`layerPrev`) and faded
 * out, revealing the already-correct bottom layer. Continuous knobs (light/dark,
 * vividness, speed) instead EASE in place, shared by both layers — a cross-fade on
 * every slider tick would thrash.
 *
 * Reactivity is zeroed (a settings thumbnail shows resting motion, not reaction to
 * absent input); a tiny black reactTex satisfies the shader's required sampler.
 * No layer/MultiEffect mask (a hidden mask source rendered empty in the KCM and
 * blanked the pane). Square corners + a 1px edge.
 */
import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: root

    // --- what to preview (bound from config.qml) ---------------------------
    property int   style: 0
    property int   theme: 0
    property real  dark: 1.0          // 1 dark · 0 light
    property real  intensity: 1.0
    property real  speed: 1.0
    property color color0: "#0d0f29"
    property color color1: "#1c2e73"
    property color color2: "#4552b8"
    property color color3: "#8f5cb8"
    property color color4: "#fa8c73"

    property int crossfadeMs: 420

    // Intrinsic size — REQUIRED: Kirigami.FormLayout sizes a field by its implicit
    // size, NOT Layout.preferred*. A bare Item implies 0×0, so the preview collapsed
    // to nothing in the dialog (rendered fine everywhere else). Callers may override.
    implicitWidth: Kirigami.Units.gridUnit * 24
    implicitHeight: Kirigami.Units.gridUnit * 12

    clip: true

    // continuous params, eased and shared by both layers (no cross-fade for these)
    property real eDark: dark
    property real eIntensity: intensity
    property real eSpeed: speed
    Behavior on eDark      { NumberAnimation { duration: 500; easing.type: Easing.InOutCubic } }
    Behavior on eIntensity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    Behavior on eSpeed     { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

    // black feedback source: the shader REQUIRES reactTex (binding 1); with no
    // excitation it samples to 0 → no reactive glow, which is what we want here.
    Rectangle { id: reactBlack; width: 8; height: 8; color: "black"; visible: false }
    ShaderEffectSource {
        id: reactSrc
        sourceItem: reactBlack
        live: false
        hideSource: true
        textureSize: Qt.size(8, 8)
    }

    // frame clock — only ticks while the dialog (and thus this item) is shown
    FrameAnimation { id: clock; running: root.visible }

    // ---- bottom layer: ALWAYS the current look (bound — never desyncs) -------
    AuroraStyleLayer {
        id: layerCur
        anchors.fill: parent
        z: 0
        iTime: clock.elapsedTime
        reactTex: reactSrc
        style: root.style
        theme: root.theme
        dark: root.eDark; intensity: root.eIntensity; speed: root.eSpeed
        color0: root.color0; color1: root.color1; color2: root.color2
        color3: root.color3; color4: root.color4
    }

    // ---- top layer: the PREVIOUS look, faded out to reveal the bottom --------
    AuroraStyleLayer {
        id: layerPrev
        anchors.fill: parent
        z: 1
        opacity: 0
        iTime: clock.elapsedTime
        reactTex: reactSrc
        // style/theme set imperatively in _flip(); continuous params shared/eased
        dark: root.eDark; intensity: root.eIntensity; speed: root.eSpeed
        color0: root.color0; color1: root.color1; color2: root.color2
        color3: root.color3; color4: root.color4
    }
    NumberAnimation {
        id: fadeOut
        target: layerPrev; property: "opacity"
        from: 1.0; to: 0.0
        duration: root.crossfadeMs; easing.type: Easing.InOutCubic
    }

    property int _pStyle: 0
    property int _pTheme: 0
    property bool _ready: false
    Component.onCompleted: { _pStyle = style; _pTheme = theme; _ready = true }

    onStyleChanged: _flip()
    onThemeChanged: _flip()

    // Paint the look we're leaving on top, then dissolve it away. layerCur already
    // shows the new look underneath, so when the fade completes the preview is
    // correct no matter how fast changes arrive.
    function _flip() {
        if (!_ready) return
        if (_pStyle === style && _pTheme === theme) return
        layerPrev.style = _pStyle
        layerPrev.theme = _pTheme
        _pStyle = style
        _pTheme = theme
        fadeOut.restart()          // from:1 snaps it opaque this tick, animates to 0
    }

    // 1px glass edge — defines the framed pane (design-ux §2)
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: Kirigami.Units.smallSpacing
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r,
                              Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.30)
    }
}
