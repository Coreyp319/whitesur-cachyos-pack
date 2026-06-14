/*
 * BridgeStatus — a small live "● running / ○ not running" indicator for a
 * systemd --user unit, so the Windows/Music reactivity sliders show whether their
 * bridge is actually up instead of silently doing nothing (design-ux §6: function
 * shouldn't depend on an effect the user can't see). Polls `systemctl --user
 * is-active <service>` on a slow cadence while visible.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as P5Support

RowLayout {
    id: root

    property string service: ""        // unit name, e.g. "nimbus-aurora-audio"
    property string hint: ""           // e.g. "audio-apply.sh" — shown when down
    property bool   active: false

    spacing: Kirigami.Units.smallSpacing

    P5Support.DataSource {
        id: probe
        engine: "executable"
        connectedSources: []
        onNewData: (src, data) => {
            root.active = ((data["stdout"] || "").trim() === "active")
            disconnectSource(src)
        }
        function check() {
            if (root.service.length > 0) connectSource("systemctl --user is-active " + root.service)
        }
    }
    Timer {
        interval: 3000; repeat: true
        running: root.visible && root.service.length > 0
        triggeredOnStart: true
        onTriggered: probe.check()
    }

    Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Kirigami.Units.gridUnit * 0.55
        implicitHeight: implicitWidth
        radius: width / 2
        color: root.active ? Kirigami.Theme.positiveTextColor
                           : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                     Kirigami.Theme.textColor.b, 0.30)
        Behavior on color { ColorAnimation { duration: 160 } }
    }

    QQC2.Label {
        text: root.active ? i18n("running")
            : (root.hint.length > 0 ? i18n("off — run %1", root.hint) : i18n("off"))
        font: Kirigami.Theme.smallFont
        color: root.active ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.textColor
        opacity: root.active ? 0.9 : 0.6
    }
}
