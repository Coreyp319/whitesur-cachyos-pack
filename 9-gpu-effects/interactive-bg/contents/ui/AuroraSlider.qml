/*
 * AuroraSlider — an expressive QQC2.Slider for the Nimbus Aurora config UI.
 *
 * The wallpaper itself (main.qml) animates everything with Behavior +
 * NumberAnimation (OutCubic 350–700ms, OutQuad audio bands); the stock config
 * sliders felt abrupt by contrast. This restyles the track + handle and adds
 * the matching micro-interactions:
 *   • accent-filled track (gradient, recolours with the live accent)
 *   • knob grows on hover (1.10) and press (1.18) with an OutBack spring
 *   • a soft drop shadow that lifts + darkens on press
 *   • the fill + knob SETTLE with an OutBack overshoot on release/click/keys,
 *     but track the cursor 1:1 while dragging (no rubber-banding)
 *   • an accent focus ring on keyboard focus
 *
 * Drop-in for QQC2.Slider: it *is* a Slider, so `value`, `from/to/stepSize`
 * and the cfg_* aliases in config.qml keep working unchanged. Same-directory
 * QML needs no import/qmldir; config.qml just writes `AuroraSlider { … }`.
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Effects
import org.kde.kirigami as Kirigami

QQC2.Slider {
    id: control

    // accent colour for the fill + focus ring; passed in from config.qml so it
    // matches the palette the user is actually editing.
    property color accentColor: Kirigami.Theme.highlightColor

    // Animated mirror of visualPosition. We animate THIS (never `value`, which
    // would lag the cursor during a drag): the Behavior is suppressed while
    // pressed so dragging tracks 1:1, then springs to the snapped value on
    // release / track-click / keyboard step.
    property real animPos: visualPosition
    Behavior on animPos {
        enabled: !control.pressed
        NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
    }
    onVisualPositionChanged: if (control.pressed) animPos = visualPosition

    implicitHeight: Kirigami.Units.gridUnit * 1.6
    implicitWidth: Kirigami.Units.gridUnit * 12

    // ---- track + accent fill -------------------------------------------------
    background: Item {
        Rectangle {
            id: groove
            x: control.handle.width / 2
            width: control.availableWidth - control.handle.width
            height: Math.max(4, Kirigami.Units.smallSpacing)
            anchors.verticalCenter: parent.verticalCenter
            radius: height / 2
            color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                           Kirigami.Theme.textColor.b, 0.18)

            Rectangle {
                width: control.animPos * parent.width
                height: parent.height
                radius: parent.radius
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: Qt.darker(control.accentColor, 1.15) }
                    GradientStop { position: 1.0; color: control.accentColor }
                }
            }
        }
    }

    // ---- handle / knob -------------------------------------------------------
    handle: Item {
        x: control.leftPadding + control.animPos * (control.availableWidth - width)
        y: control.topPadding + control.availableHeight / 2 - height / 2
        implicitWidth:  Kirigami.Units.gridUnit * 1.05
        implicitHeight: Kirigami.Units.gridUnit * 1.05

        Rectangle {
            id: knob
            anchors.fill: parent
            radius: width / 2
            color: Kirigami.Theme.backgroundColor   // adapts to the dialog scheme

            // On a dark scheme the knob fill is dark and the black drop-shadow
            // below can't separate it from the accent fill / groove, so the
            // handle vanishes. Give it a luminance-adaptive rim: a light edge
            // on dark schemes (keeps the outline >=3:1 against the accent
            // fill), the original subtle dark edge on light ones.
            readonly property bool onDark: Kirigami.Theme.backgroundColor.hslLightness < 0.5
            border.width: onDark ? 1.5 : 1
            border.color: onDark
                ? Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                          Kirigami.Theme.textColor.b, 0.75)
                : Qt.rgba(0, 0, 0, 0.10)

            // engaged = being hovered / pressed / keyboard-focused
            readonly property bool active: control.pressed || control.hovered || control.visualFocus

            scale: control.pressed ? 1.18 : (control.hovered ? 1.10 : 1.0)
            Behavior on scale {
                NumberAnimation { duration: 150; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
            }

            // GPU drop-shadow / accent-glow. QtQuick.Effects.MultiEffect is Qt 6's
            // built-in shader effect (no Qt5Compat dependency). Idle: a soft dark
            // drop shadow. Engaged: the shadow recolours to the accent and blooms
            // outward into a real glow — every transition animated on the GPU.
            layer.enabled: true
            layer.smooth: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                blurMax: 24
                shadowEnabled: true
                shadowColor: knob.active ? control.accentColor : Qt.rgba(0, 0, 0, 0.38)
                shadowBlur: knob.active ? 0.75 : 0.45
                shadowScale: knob.active ? 1.12 : 1.0
                shadowVerticalOffset: control.pressed ? 1 : (knob.active ? 0 : 3)
                shadowOpacity: knob.active ? 0.85 : 0.55
                Behavior on shadowColor          { ColorAnimation  { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on shadowBlur           { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on shadowScale          { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                Behavior on shadowVerticalOffset { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on shadowOpacity        { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            }
        }

        // Crisp accent focus ring (keyboard focus). Kept a SIBLING of the layered
        // knob so the layer texture doesn't clip it — it extends past the knob.
        Rectangle {
            anchors.centerIn: parent
            width: parent.width + 8
            height: parent.height + 8
            radius: width / 2
            color: "transparent"
            border.width: 2
            border.color: control.accentColor
            opacity: control.visualFocus ? 0.9 : 0.0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }
    }
}
