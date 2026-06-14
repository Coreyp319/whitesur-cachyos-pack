/*
 * Settings page for Nimbus Aurora (System Settings → Wallpaper → Configure).
 * Property names are cfg_<Key> — Plasma binds them to contents/config/main.xml.
 *
 * Layout: the live Preview is the hero up top; the two appearance pickers (Style,
 * then the Theme gallery) feed it directly beneath; the Custom palette unfolds right
 * under the Theme gallery (adjacent to the card that reveals it); Light/dark is a
 * segmented control. Below that, two labelled sections — "Motion & colour" and
 * "Reactivity" — hold the sliders, the reactivity ones showing live bridge status.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

Kirigami.FormLayout {
    id: cfg
    twinFormLayouts: parentLayout

    // Plasma reads/writes these (cfg_<Key>) against main.xml's <entry>s.
    property alias cfg_Theme: themeGrid.currentIndex
    property alias cfg_Style: styleBox.currentIndex
    property alias cfg_Appearance: appearanceSeg.currentIndex
    property alias cfg_Speed: speedSlider.value
    property alias cfg_Intensity: intensitySlider.value
    property alias cfg_Interactivity: interSlider.value
    property alias cfg_WindowReact: winReactSlider.value
    property alias cfg_MusicReact: musicReactSlider.value
    property alias cfg_Color0: c0.color
    property alias cfg_Color1: c1.color
    property alias cfg_Color2: c2.color
    property alias cfg_Color3: c3.color
    property alias cfg_Color4: c4.color

    readonly property bool customTheme: themeGrid.currentIndex === 9
    // Accent that the expressive controls fill with. In Custom mode it tracks the
    // live "Accent" stop (c3) so fills recolour as you edit; for the presets fall
    // back to Plasma's accent so the form stays scheme-cohesive.
    readonly property color auroraAccent: customTheme ? c3.color : Kirigami.Theme.highlightColor

    // Light/dark the live preview should render. Mirrors the wallpaper's own logic:
    // 1 = always light, 2 = always dark, 0 = follow — and "follow" reads the active
    // Plasma scheme via Kirigami.Theme (which DOES track it inside a KCM, unlike the
    // wallpaper context), so the preview flips with the dock's light/dark toggle.
    readonly property real previewDark:
        appearanceSeg.currentIndex === 1 ? 0.0 :
        appearanceSeg.currentIndex === 2 ? 1.0 :
        (0.299 * Kirigami.Theme.backgroundColor.r
       + 0.587 * Kirigami.Theme.backgroundColor.g
       + 0.114 * Kirigami.Theme.backgroundColor.b) < 0.5 ? 1.0 : 0.0

    // Honour KDE "Animation speed = Instant" (AnimationDurationFactor 0): freeze the
    // preview's drift and make Style/Theme swaps instant instead of cross-fading.
    property bool reduceMotion: false
    P5Support.DataSource {
        id: motionProbe
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            const s = (data["stdout"] || "").trim()
            if (s.length > 0) cfg.reduceMotion = parseFloat(s) === 0.0
            disconnectSource(source)
        }
        function probe() { connectSource("kreadconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor") }
    }
    Timer { interval: 2000; repeat: true; running: true; triggeredOnStart: true; onTriggered: motionProbe.probe() }

    // Palette previews for the Theme picker — the five stops (dark → bright) each
    // theme actually applies, so the colour scheme is VISIBLE, not just named. MUST
    // mirror palette() in contents/shaders/aurora.frag (the dark design variant); the
    // last row is Custom and binds LIVE to the colour buttons below, so its card
    // recolours as you edit. Keep in sync if the shader changes.
    readonly property var themePalettes: [
        ["#0d0f29", "#1c2e73", "#4552b8", "#8f5cb8", "#fa8c73"], // Big Sur
        ["#0a1733", "#126185", "#3385c7", "#9e70bd", "#f5a8b8"], // Monterey
        ["#12141a", "#292e38", "#525966", "#8c94a3", "#d1d9e6"], // Graphite
        ["#1a0d2e", "#591a4d", "#b83861", "#f27347", "#ffcc73"], // Sunset
        ["#2e3340", "#3b4252", "#5e82ab", "#87bfd1", "#d9dee8"], // Nord
        ["#120a1f", "#29144d", "#8c29b3", "#f259bd", "#38e6eb"], // Laserwave
        ["#1f1238", "#613d8f", "#bd6bf2", "#ff73cc", "#66e0fa"], // Vaporwave
        ["#05050d", "#0a243d", "#0094c2", "#ff298f", "#faeb33"], // Cyberpunk
        ["#0d0529", "#330f66", "#d9268c", "#ff6b4d", "#ffdb4d"], // Outrun
        [c0.color, c1.color, c2.color, c3.color, c4.color]       // Custom (live)
    ]
    readonly property var themeNames: [
        i18n("Big Sur"), i18n("Monterey"), i18n("Graphite"),
        i18n("Sunset"), i18n("Nord"),
        i18n("Laserwave"), i18n("Vaporwave"), i18n("Cyberpunk"), i18n("Outrun"),
        i18n("Custom…")
    ]

    // --- the hero: live preview, with the two pickers feeding it beneath --------
    AuroraPreview {
        Kirigami.FormData.label: i18n("Preview:")
        style: styleBox.currentIndex
        theme: themeGrid.currentIndex
        dark: cfg.previewDark
        intensity: intensitySlider.value
        speed: cfg.reduceMotion ? 0.0 : speedSlider.value
        crossfadeMs: cfg.reduceMotion ? 0 : 420
        color0: c0.color; color1: c1.color; color2: c2.color
        color3: c3.color; color4: c4.color
        // FormLayout sizes fields by implicit size; AuroraPreview supplies a sane
        // default (gridUnit 24×12). Override here to resize the preview pane.
        implicitWidth: Kirigami.Units.gridUnit * 24
        implicitHeight: Kirigami.Units.gridUnit * 12
    }

    AuroraComboBox {
        id: styleBox
        accentColor: cfg.auroraAccent
        Kirigami.FormData.label: i18n("Style:")
        model: [i18n("Flow"), i18n("Hills"),
                i18n("Silk curtains"), i18n("Caustics"), i18n("Ink in water"),
                i18n("Laserwave"), i18n("Vaporwave"), i18n("Cyberpunk"),
                i18n("Liquid (fluid sim)")]

        // Per-style presets: snap the motion-character sliders to values tuned for
        // each look. Uses onActivated (a USER pick) — NOT onCurrentIndexChanged — so
        // opening the dialog or loading saved config never overwrites your tweaks.
        readonly property var speedPreset:     [1.00, 0.60, 0.80, 1.10, 0.70, 1.00, 0.70, 1.00, 0.85]
        readonly property var intensityPreset: [1.00, 1.00, 1.15, 0.95, 1.00, 1.10, 1.00, 1.10, 1.00]
        onActivated: {
            speedSlider.value     = styleBox.speedPreset[styleBox.currentIndex]
            intensitySlider.value = styleBox.intensityPreset[styleBox.currentIndex]
        }
    }
    // Disambiguate the two appearance axes — they share some names (Laserwave,
    // Vaporwave, Cyberpunk live in BOTH lists), which reads as duplication.
    QQC2.Label {
        text: i18n("Style is the shape & motion; the Theme below sets the colours.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        Layout.maximumWidth: Kirigami.Units.gridUnit * 18
        wrapMode: Text.WordWrap
    }

    // Theme picker: a visible, clickable gallery of palette cards (not a dropdown),
    // so every colour scheme is on show and one click away. currentIndex drives
    // cfg_Theme; the Custom card recolours live from the palette editor below.
    AuroraThemeGrid {
        id: themeGrid
        Kirigami.FormData.label: i18n("Theme:")
        accentColor: cfg.auroraAccent
        names: cfg.themeNames
        palettes: cfg.themePalettes
    }

    // --- custom palette: unfolds right under the gallery, adjacent to the card ---
    Kirigami.Separator {
        Kirigami.FormData.label: i18n("Custom palette")
        Kirigami.FormData.isSection: true
        visible: cfg.customTheme
    }
    QQC2.Label {
        visible: cfg.customTheme
        text: i18n("Five stops, dark → bright — your Custom theme.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
    }
    AuroraColorButton { id: c0; Kirigami.FormData.label: i18n("Shadow:");     visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c1; Kirigami.FormData.label: i18n("Deep:");       visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c2; Kirigami.FormData.label: i18n("Mid:");        visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c3; Kirigami.FormData.label: i18n("Accent:");     visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c4; Kirigami.FormData.label: i18n("Highlight:");  visible: cfg.customTheme; showAlphaChannel: false }

    AuroraSegmented {
        id: appearanceSeg
        accentColor: cfg.auroraAccent
        Kirigami.FormData.label: i18n("Light/dark:")
        model: [i18n("Follow"), i18n("Light"), i18n("Dark")]
    }

    // --- motion & colour (the aurora's resting character) ----------------------
    Kirigami.Separator {
        Kirigami.FormData.label: i18n("Motion & colour")
        Kirigami.FormData.isSection: true
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Motion:")
        AuroraSlider {
            id: speedSlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 2.5; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: speedSlider.value.toFixed(2) + "×" }
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Vividness:")
        AuroraSlider {
            id: intensitySlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 2.0; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: Math.round(intensitySlider.value * 100) + "%" }
    }

    // --- reactivity (how strongly the aurora responds to each source) ----------
    // Each bridge-backed source shows live status, so a slider that does nothing
    // because its bridge is down reads as "off — run X", not a mystery.
    Kirigami.Separator {
        Kirigami.FormData.label: i18n("Reactivity")
        Kirigami.FormData.isSection: true
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Cursor:")
        AuroraSlider {
            id: interSlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 1.0; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: Math.round(interSlider.value * 100) + "%" }
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Windows:")
        AuroraSlider {
            id: winReactSlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 1.0; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: Math.round(winReactSlider.value * 100) + "%" }
        BridgeStatus { Layout.leftMargin: Kirigami.Units.smallSpacing
                       service: "nimbus-aurora-bridge"; hint: "windows-apply.sh" }
    }
    QQC2.Label {
        text: i18n("Drag a window and the aurora bends + glows around it.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        Layout.maximumWidth: Kirigami.Units.gridUnit * 18
        wrapMode: Text.WordWrap
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Music:")
        AuroraSlider {
            id: musicReactSlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 1.0; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: Math.round(musicReactSlider.value * 100) + "%" }
        BridgeStatus { Layout.leftMargin: Kirigami.Units.smallSpacing
                       service: "nimbus-aurora-audio"; hint: "audio-apply.sh" }
    }
    QQC2.Label {
        text: i18n("The aurora pulses with whatever's playing — bass swells, beats ripple.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        Layout.maximumWidth: Kirigami.Units.gridUnit * 18
        wrapMode: Text.WordWrap
    }
}
