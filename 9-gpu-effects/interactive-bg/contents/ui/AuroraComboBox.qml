/*
 * AuroraComboBox — an expressive QQC2.ComboBox for the Nimbus Aurora config UI,
 * matching AuroraSlider's language so the whole form feels of-a-piece.
 *
 * Micro-interactions:
 *   • field border + GPU shadow bloom to the accent on hover / focus / open
 *   • the chevron rotates 180° (OutBack) when the popup opens, and tints accent
 *   • the popup fades + springs in (scale OutBack) with a soft GPU drop shadow
 *   • list items highlight with an accent wash, accent text on the current row
 *
 * Drop-in for QQC2.ComboBox: still a ComboBox, so `model` / `currentIndex` and
 * the cfg_* aliases in config.qml keep working. Same-directory QML needs no
 * import/qmldir.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Effects
import org.kde.kirigami as Kirigami

QQC2.ComboBox {
    id: control

    property color accentColor: Kirigami.Theme.highlightColor

    // Optional per-row colour previews. `swatches[i]` is an array of colours for
    // item i (or null/undefined for none) — when set, a gradient chip renders in
    // the field and each dropdown row so the palette is VISIBLE, not just named.
    // Leave empty (the default) and the box behaves like a plain text ComboBox.
    property var swatches: []
    function swatchFor(i) {
        return (swatches && i >= 0 && i < swatches.length && swatches[i]) ? swatches[i] : null
    }
    readonly property bool hasSwatches: swatches && swatches.length > 0

    implicitHeight: Kirigami.Units.gridUnit * 1.8
    // widen when chips are shown so the name still fits beside the swatch
    implicitWidth: hasSwatches ? Kirigami.Units.gridUnit * 11 : Kirigami.Units.gridUnit * 9
    leftPadding: Kirigami.Units.largeSpacing
    rightPadding: Kirigami.Units.gridUnit * 1.9

    // engaged = hovered / keyboard-focused / popup open
    readonly property bool active: hovered || visualFocus || popup.visible

    // ---- selected-value label (+ optional palette chip) ---------------------
    contentItem: RowLayout {
        spacing: Kirigami.Units.smallSpacing
        AuroraSwatch {
            visible: control.swatchFor(control.currentIndex) !== null
            colors: control.swatchFor(control.currentIndex) || []
            Layout.preferredWidth: Kirigami.Units.gridUnit * 2.0
            Layout.preferredHeight: Kirigami.Units.gridUnit * 0.95
            Layout.alignment: Qt.AlignVCenter
        }
        QQC2.Label {
            text: control.displayText
            color: Kirigami.Theme.textColor
            font: control.font
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }

    // ---- chevron -------------------------------------------------------------
    indicator: Canvas {
        id: chevron
        x: control.width - width - Kirigami.Units.largeSpacing
        y: (control.height - height) / 2
        width: Kirigami.Units.gridUnit * 0.7
        height: width
        rotation: control.popup.visible ? 180 : 0
        Behavior on rotation { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }

        // stroke drives the chevron colour; onStrokeChanged repaints on every
        // animation step, so the colour eases smoothly without a running hook.
        property color stroke: control.active ? control.accentColor : Kirigami.Theme.textColor
        onStrokeChanged: requestPaint()
        Behavior on stroke { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            ctx.strokeStyle = stroke;
            ctx.lineWidth = 2;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            ctx.beginPath();
            ctx.moveTo(width * 0.25, height * 0.40);
            ctx.lineTo(width * 0.50, height * 0.63);
            ctx.lineTo(width * 0.75, height * 0.40);
            ctx.stroke();
        }
    }

    // ---- field background (GPU shadow blooms accent when engaged) ------------
    background: Rectangle {
        id: field
        radius: Kirigami.Units.smallSpacing + 1
        color: Kirigami.Theme.backgroundColor
        border.width: control.active ? 2 : 1
        border.color: control.active
            ? control.accentColor
            : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.25)
        Behavior on border.color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }

        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
            autoPaddingEnabled: true
            blurMax: 20
            shadowEnabled: true
            shadowColor: control.active ? control.accentColor : Qt.rgba(0, 0, 0, 0.32)
            shadowBlur: control.active ? 0.6 : 0.32
            shadowScale: control.active ? 1.04 : 1.0
            shadowVerticalOffset: 2
            shadowOpacity: control.active ? 0.55 : 0.4
            Behavior on shadowColor   { ColorAnimation  { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on shadowBlur    { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on shadowScale   { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on shadowOpacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        }
    }

    // ---- dropdown popup ------------------------------------------------------
    popup: QQC2.Popup {
        y: control.height + Kirigami.Units.smallSpacing
        width: control.width
        implicitHeight: Math.min(contentItem.implicitHeight + topPadding + bottomPadding,
                                 Kirigami.Units.gridUnit * 16)
        padding: Kirigami.Units.smallSpacing

        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            QQC2.ScrollIndicator.vertical: QQC2.ScrollIndicator { }
        }

        background: Rectangle {
            radius: Kirigami.Units.smallSpacing + 2
            color: Kirigami.Theme.backgroundColor
            border.width: 1
            border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.18)
            layer.enabled: true
            layer.smooth: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                blurMax: 32
                shadowEnabled: true
                shadowColor: Qt.rgba(0, 0, 0, 0.40)
                shadowBlur: 0.85
                shadowVerticalOffset: 6
                shadowOpacity: 0.6
            }
        }

        enter: Transition {
            NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 140; easing.type: Easing.OutCubic }
            NumberAnimation { property: "scale"; from: 0.95; to: 1.0; duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }
        exit: Transition {
            NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 120; easing.type: Easing.InCubic }
            NumberAnimation { property: "scale"; from: 1.0; to: 0.97; duration: 120; easing.type: Easing.InCubic }
        }
    }

    // ---- list item -----------------------------------------------------------
    delegate: QQC2.ItemDelegate {
        id: itemDelegate
        required property var modelData
        required property int index
        width: ListView.view ? ListView.view.width : implicitWidth
        text: itemDelegate.modelData
        highlighted: control.highlightedIndex === index

        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing
            AuroraSwatch {
                visible: control.swatchFor(itemDelegate.index) !== null
                colors: control.swatchFor(itemDelegate.index) || []
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2.4
                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.0
                Layout.alignment: Qt.AlignVCenter
            }
            QQC2.Label {
                text: itemDelegate.text
                color: itemDelegate.highlighted ? control.accentColor : Kirigami.Theme.textColor
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }

        background: Rectangle {
            radius: Kirigami.Units.smallSpacing
            color: itemDelegate.highlighted
                   ? Qt.rgba(control.accentColor.r, control.accentColor.g, control.accentColor.b, 0.16)
                   : "transparent"
            Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }
        }
    }
}
