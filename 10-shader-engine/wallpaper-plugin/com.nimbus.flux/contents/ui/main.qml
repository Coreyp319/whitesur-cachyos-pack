/*
 * Nimbus Flux — wallpaper-plugin launcher (Plasma 6).
 *
 * This wallpaper renders nothing of its own: it is a thin lifecycle manager for the
 * standalone Layer-10 bevy/wgpu engine (`nimbus-flux --wallpaper`), which draws onto a
 * wlr-layer-shell *background* surface that sits ABOVE this Plasma wallpaper. Selecting
 * this wallpaper type launches the engine; switching to any other wallpaper tears it
 * down (Component.onDestruction here + the launcher's appletsrc watchdog) so Settings
 * can switch between wallpaper types seamlessly. The chosen scene comes from
 * contents/config/main.xml (Scene) and maps to the engine's NIMBUS_FLUX_SCENE.
 */
import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support

WallpaperItem {
    id: root

    readonly property string cfgScene: configuration.Scene ?? "cyberpunk"

    // A black backdrop sits under the engine's layer-shell surface (which covers it).
    // It also shows for the ~1 s before the surface maps, and if the engine is absent.
    Rectangle {
        anchors.fill: parent
        color: "black"
    }

    // The executable engine — runs a shell command (so $HOME expands). Fire-and-forget:
    // disconnect each source in onNewData so the same command can be issued again.
    P5Support.DataSource {
        id: runner
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => disconnectSource(source)
        function run(cmd) { connectSource(cmd) }
    }

    function startEngine() {
        runner.run("$HOME/.local/bin/nimbus-flux-wallpaper " + cfgScene)
    }
    function stopEngine() {
        runner.run("$HOME/.local/bin/nimbus-flux-wallpaper --stop")
    }

    Component.onCompleted: startEngine()    // became the active desktop wallpaper
    Component.onDestruction: stopEngine()   // switched away to another wallpaper
    onCfgSceneChanged: startEngine()        // scene changed in config -> relaunch
}
