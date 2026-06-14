/*
 * Settings page for Nimbus Flux (System Settings → Wallpaper → Configure).
 * Property names are cfg_<Key> — Plasma binds them to contents/config/main.xml.
 * A single Scene dropdown chooses which Layer-10 engine scene runs.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: cfg
    twinFormLayouts: parentLayout

    // Plasma reads/writes this against main.xml's <entry name="Scene">.
    property string cfg_Scene: "cyberpunk"
    property string cfg_SceneDefault: "cyberpunk"

    QQC2.ComboBox {
        id: sceneBox
        Kirigami.FormData.label: i18n("Scene:")
        textRole: "label"
        valueRole: "value"
        implicitWidth: Kirigami.Units.gridUnit * 16
        model: [
            { label: i18n("Cyberpunk city"),        value: "cyberpunk" },
            { label: i18n("Gothic dungeon (Hexen)"), value: "hexen" },
            { label: i18n("Fluid simulation"),       value: "fluid" }
        ]
        currentIndex: Math.max(0, indexOfValue(cfg.cfg_Scene))
        onActivated: cfg.cfg_Scene = currentValue
    }

    QQC2.Label {
        Kirigami.FormData.label: ""
        text: i18n("The 3-D engine renders on a layer-shell surface above the desktop, so it\n" +
                   "covers desktop icons while active. Switching to another wallpaper stops it.")
        opacity: 0.7
        font: Kirigami.Theme.smallFont
        wrapMode: Text.WordWrap
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
    }
}
