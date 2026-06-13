/*
 * Settings page for Nimbus Aurora (System Settings → Wallpaper → Configure).
 * Property names are cfg_<Key> — Plasma binds them to contents/config/main.xml.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: cfg
    twinFormLayouts: parentLayout

    // Plasma reads/writes these (cfg_<Key>) against main.xml's <entry>s.
    property alias cfg_Theme: themeBox.currentIndex
    property alias cfg_Style: styleBox.currentIndex
    property alias cfg_Appearance: appearanceBox.currentIndex
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

    readonly property bool customTheme: themeBox.currentIndex === 9
    // Accent that the expressive AuroraSliders fill with. In Custom mode it
    // tracks the live "Accent" stop (c3) so fills recolour as you edit; for the
    // presets fall back to Plasma's accent so the form stays scheme-cohesive.
    readonly property color auroraAccent: customTheme ? c3.color : Kirigami.Theme.highlightColor

    AuroraComboBox {
        id: themeBox
        accentColor: cfg.auroraAccent
        Kirigami.FormData.label: i18n("Theme:")
        model: [i18n("Big Sur"), i18n("Monterey"), i18n("Graphite"),
                i18n("Sunset"), i18n("Nord"),
                i18n("Laserwave"), i18n("Vaporwave"), i18n("Cyberpunk"), i18n("Outrun"),
                i18n("Custom…")]
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
        // each look — Hills/Ink want a slow drift, Caustics a touch quicker shimmer,
        // Silk a little extra vividness (it reads faint); Laserwave/Cyberpunk a touch
        // more neon punch, Vaporwave a dreamier drift. Indexed Flow·Hills·Silk·
        // Caustics·Ink·Laserwave·Vaporwave·Cyberpunk. Uses onActivated (a USER pick) —
        // NOT onCurrentIndexChanged — so opening the dialog or loading saved config
        // never overwrites your tweaks.
        readonly property var speedPreset:     [1.00, 0.60, 0.80, 1.10, 0.70, 1.00, 0.70, 1.00, 0.85]
        readonly property var intensityPreset: [1.00, 1.00, 1.15, 0.95, 1.00, 1.10, 1.00, 1.10, 1.00]
        onActivated: {
            speedSlider.value     = styleBox.speedPreset[styleBox.currentIndex]
            intensitySlider.value = styleBox.intensityPreset[styleBox.currentIndex]
        }
    }

    AuroraComboBox {
        id: appearanceBox
        accentColor: cfg.auroraAccent
        Kirigami.FormData.label: i18n("Light/dark:")
        model: [i18n("Follow colour scheme"), i18n("Always light"), i18n("Always dark")]
    }

    // --- custom palette (only meaningful when Theme = Custom) --------------
    Kirigami.Separator {
        Kirigami.FormData.label: i18n("Custom palette")
        Kirigami.FormData.isSection: true
        visible: cfg.customTheme
    }
    QQC2.Label {
        visible: cfg.customTheme
        text: i18n("Five stops, dark → bright. Pick “Custom…” above to use them.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
    }

    AuroraColorButton { id: c0; Kirigami.FormData.label: i18n("Shadow:");     visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c1; Kirigami.FormData.label: i18n("Deep:");       visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c2; Kirigami.FormData.label: i18n("Mid:");        visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c3; Kirigami.FormData.label: i18n("Accent:");     visible: cfg.customTheme; showAlphaChannel: false }
    AuroraColorButton { id: c4; Kirigami.FormData.label: i18n("Highlight:");  visible: cfg.customTheme; showAlphaChannel: false }

    Item { Kirigami.FormData.isSection: true }

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
        Kirigami.FormData.label: i18n("Cursor influence:")
        AuroraSlider {
            id: interSlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 1.0; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: Math.round(interSlider.value * 100) + "%" }
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

    RowLayout {
        Kirigami.FormData.label: i18n("React to windows:")
        AuroraSlider {
            id: winReactSlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 1.0; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: Math.round(winReactSlider.value * 100) + "%" }
    }
    QQC2.Label {
        text: i18n("Drag a window and the aurora bends + glows around it. Needs the "
                 + "window bridge from Layer 9 (windows-apply.sh) running.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        Layout.maximumWidth: Kirigami.Units.gridUnit * 18
        wrapMode: Text.WordWrap
    }

    RowLayout {
        Kirigami.FormData.label: i18n("React to music:")
        AuroraSlider {
            id: musicReactSlider
            accentColor: cfg.auroraAccent
            from: 0.0; to: 1.0; stepSize: 0.05
            Layout.preferredWidth: Kirigami.Units.gridUnit * 12
        }
        QQC2.Label { text: Math.round(musicReactSlider.value * 100) + "%" }
    }
    QQC2.Label {
        text: i18n("The aurora pulses with whatever's playing — bass swells, beats "
                 + "ripple. Needs the audio bridge from Layer 9 (audio-apply.sh) running.")
        font: Kirigami.Theme.smallFont
        opacity: 0.7
        Layout.maximumWidth: Kirigami.Units.gridUnit * 18
        wrapMode: Text.WordWrap
    }
}
