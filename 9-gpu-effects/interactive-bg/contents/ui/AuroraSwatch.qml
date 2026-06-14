/*
 * AuroraSwatch — a rounded "chip" that paints a horizontal 5-stop gradient from a
 * colours array, so a theme's palette is VISIBLE at a glance instead of hiding
 * behind a name. The gradient mirrors how aurora.frag ramps c0..c4, so the chip
 * previews the look the wallpaper actually applies.
 *
 * Tactile by the form's language: a soft GPU drop-shadow lifts it off the surface
 * and a 1px hairline (the Big-Sur glass edge) defines it. `colors` accepts colour
 * strings or live `color`s — Custom's chip can bind straight to the colour buttons.
 */
import QtQuick
import QtQuick.Effects
import org.kde.kirigami as Kirigami

Item {
    id: root

    property var  colors: []                         // array of color | "#rrggbb"
    property real radius: Kirigami.Units.smallSpacing + 1

    implicitWidth: Kirigami.Units.gridUnit * 2.2
    implicitHeight: Kirigami.Units.gridUnit * 1.05

    onColorsChanged: chip.requestPaint()
    onWidthChanged:  chip.requestPaint()
    onHeightChanged: chip.requestPaint()

    // GPU drop-shadow so the chip reads as a physical swatch, matching the
    // AuroraSlider/ComboBox depth language.
    layer.enabled: true
    layer.smooth: true
    layer.effect: MultiEffect {
        autoPaddingEnabled: true
        blurMax: 12
        shadowEnabled: true
        shadowColor: Qt.rgba(0, 0, 0, 0.35)
        shadowBlur: 0.3
        shadowVerticalOffset: 1
        shadowOpacity: 0.4
    }

    Canvas {
        id: chip
        anchors.fill: parent
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height, r = Math.min(root.radius, h / 2);
            // rounded-rect clip
            ctx.beginPath();
            ctx.moveTo(r, 0);
            ctx.arcTo(w, 0, w, h, r);
            ctx.arcTo(w, h, 0, h, r);
            ctx.arcTo(0, h, 0, 0, r);
            ctx.arcTo(0, 0, w, 0, r);
            ctx.closePath();
            ctx.clip();

            var cs = root.colors;
            if (cs && cs.length > 0) {
                var grad = ctx.createLinearGradient(0, 0, w, 0);
                var n = cs.length;
                for (var i = 0; i < n; i++) {
                    // normalise color|string -> css rgb (avoids #aarrggbb ambiguity)
                    var c = (typeof cs[i] === "string") ? Qt.color(cs[i]) : cs[i];
                    var css = "rgb(" + Math.round(c.r * 255) + ","
                                     + Math.round(c.g * 255) + ","
                                     + Math.round(c.b * 255) + ")";
                    grad.addColorStop(n === 1 ? 0 : i / (n - 1), css);
                }
                ctx.fillStyle = grad;
            } else {
                ctx.fillStyle = "transparent";
            }
            ctx.fillRect(0, 0, w, h);
        }
    }

    // 1px glass edge — defines the chip for low-vision users (design-ux §2).
    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r,
                              Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.30)
    }
}
