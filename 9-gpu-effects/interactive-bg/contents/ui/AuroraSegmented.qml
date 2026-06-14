/*
 * AuroraSegmented — a tactile segmented button group for a small set of mutually
 * exclusive options (the Light/dark choice), instead of a dropdown that hides the
 * alternatives. Matches the form's expressive language: accent-filled selection,
 * hover wash, 1px glass edge. Exposes a read/write `currentIndex` so the cfg_*
 * alias keeps binding. Left/Right arrows move the selection when focused.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: root

    property color accentColor: Kirigami.Theme.highlightColor
    property var   model: []
    property int   currentIndex: 0

    implicitWidth: frame.implicitWidth
    implicitHeight: Kirigami.Units.gridUnit * 1.8

    activeFocusOnTab: true
    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Right) { currentIndex = Math.min(model.length - 1, currentIndex + 1); e.accepted = true }
        else if (e.key === Qt.Key_Left) { currentIndex = Math.max(0, currentIndex - 1); e.accepted = true }
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        implicitWidth: rowLayout.implicitWidth + 4
        radius: Kirigami.Units.smallSpacing + 2
        color: Kirigami.Theme.backgroundColor
        border.width: root.activeFocus ? 2 : 1
        border.color: root.activeFocus
            ? root.accentColor
            : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.25)
        Behavior on border.color { ColorAnimation { duration: 140 } }

        RowLayout {
            id: rowLayout
            anchors.fill: parent
            anchors.margins: 2
            spacing: 0

            Repeater {
                model: root.model
                delegate: Item {
                    id: seg
                    required property int index
                    required property var modelData
                    readonly property bool selected: root.currentIndex === index

                    Layout.fillHeight: true
                    Layout.preferredWidth: label.implicitWidth + Kirigami.Units.largeSpacing * 2

                    Rectangle {
                        anchors.fill: parent
                        radius: Kirigami.Units.smallSpacing
                        color: seg.selected
                            ? root.accentColor
                            : (segHover.hovered
                               ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.14)
                               : "transparent")
                        Behavior on color { ColorAnimation { duration: 130; easing.type: Easing.OutCubic } }
                    }

                    QQC2.Label {
                        id: label
                        anchors.centerIn: parent
                        text: seg.modelData
                        font: Kirigami.Theme.smallFont
                        color: seg.selected ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
                        Behavior on color { ColorAnimation { duration: 130 } }
                    }

                    HoverHandler { id: segHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: { root.currentIndex = seg.index; root.forceActiveFocus() } }
                }
            }
        }
    }
}
