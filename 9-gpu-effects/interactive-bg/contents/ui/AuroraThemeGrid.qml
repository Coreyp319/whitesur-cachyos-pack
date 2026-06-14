/*
 * AuroraThemeGrid — the Theme picker as a visible, clickable gallery instead of a
 * dropdown. Each card shows the theme's real palette (AuroraSwatch gradient) + name;
 * the selected card gets an accent ring + accent label, hover gives a spring lift.
 *
 * Drop-in for the old AuroraComboBox theme field: exposes a read/write `currentIndex`
 * so the `cfg_Theme` alias in config.qml keeps binding. `palettes` may rebind live
 * (Custom's stops) and the matching card recolours. Arrow keys move the selection.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: root

    property color accentColor: Kirigami.Theme.highlightColor
    property var   names: []            // [string]
    property var   palettes: []         // [[color,...]] — index-aligned with names
    property int   currentIndex: 0

    property int   columns: 5
    property real  cardWidth: Kirigami.Units.gridUnit * 4.2
    property real  swatchHeight: Kirigami.Units.gridUnit * 2.1

    implicitWidth: grid.implicitWidth
    implicitHeight: grid.implicitHeight

    activeFocusOnTab: true
    Keys.onPressed: (e) => {
        var n = names.length, c = columns
        if (e.key === Qt.Key_Right)      { currentIndex = Math.min(n - 1, currentIndex + 1); e.accepted = true }
        else if (e.key === Qt.Key_Left)  { currentIndex = Math.max(0, currentIndex - 1);     e.accepted = true }
        else if (e.key === Qt.Key_Down)  { currentIndex = Math.min(n - 1, currentIndex + c); e.accepted = true }
        else if (e.key === Qt.Key_Up)    { currentIndex = Math.max(0, currentIndex - c);     e.accepted = true }
    }
    // soft accent frame when the grid has keyboard focus (focus visibility)
    Rectangle {
        anchors.fill: parent
        anchors.margins: -Kirigami.Units.smallSpacing
        radius: Kirigami.Units.smallSpacing + 2
        color: "transparent"
        border.width: 1
        border.color: root.accentColor
        opacity: root.activeFocus ? 0.5 : 0.0
        Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    GridLayout {
        id: grid
        columns: root.columns
        rowSpacing: Kirigami.Units.smallSpacing
        columnSpacing: Kirigami.Units.smallSpacing

        Repeater {
            model: root.names.length
            delegate: Item {
                id: card
                required property int index
                readonly property bool selected: root.currentIndex === index

                Layout.preferredWidth: root.cardWidth
                Layout.preferredHeight: root.swatchHeight + nameLabel.implicitHeight
                                        + Kirigami.Units.smallSpacing

                scale: selected ? 1.04 : (hover.hovered ? 1.06 : 1.0)
                Behavior on scale {
                    NumberAnimation { duration: 150; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
                }
                z: selected || hover.hovered ? 1 : 0

                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { root.currentIndex = card.index; root.forceActiveFocus() } }

                ColumnLayout {
                    anchors.fill: parent
                    spacing: Kirigami.Units.smallSpacing

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.swatchHeight

                        AuroraSwatch {
                            anchors.fill: parent
                            colors: root.palettes[card.index] || []
                        }
                        // selection / hover ring over the swatch
                        Rectangle {
                            anchors.fill: parent
                            radius: Kirigami.Units.smallSpacing + 1
                            color: "transparent"
                            border.width: (card.selected || hover.hovered) ? 2 : 0
                            border.color: root.accentColor
                            opacity: card.selected ? 1.0 : (hover.hovered ? 0.55 : 0.0)
                            Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
                        }
                    }

                    QQC2.Label {
                        id: nameLabel
                        Layout.fillWidth: true
                        text: root.names[card.index] || ""
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        font: Kirigami.Theme.smallFont
                        color: card.selected ? root.accentColor : Kirigami.Theme.textColor
                        opacity: card.selected ? 1.0 : 0.85
                    }
                }
            }
        }
    }
}
