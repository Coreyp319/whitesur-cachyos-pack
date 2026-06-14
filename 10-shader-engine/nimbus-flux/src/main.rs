//! Nimbus Flux — standalone GPU shader engine (Nimbus pack, Layer 10).
//!
//! A bevy/wgpu app running a real GPU compute-shader fluid simulation, separate
//! from the KDE desktop. See `fluid.rs` for the solver.
//!
//! Controls: move/drag the cursor to push the fluid and inject dye.
//!   1 / 2 / 3  switch style (ink / mercury / water)   ·   D  toggle light/dark
//!
//! Setting `NIMBUS_FLUX_CAPTURE=1` runs a headless-style check: save a frame to
//! /tmp/nimbus-flux-frame.png at ~4s, log average FPS, then exit at ~6s.

mod fluid;
mod hero;
mod scene_cyberpunk;
mod scene_hexen;
mod scene_journey;
mod window_react;

use bevy::{
    diagnostic::{DiagnosticsStore, FrameTimeDiagnosticsPlugin},
    prelude::*,
    render::view::screenshot::{save_to_disk, Screenshot},
    window::PresentMode,
};
use bevy_live_wallpaper::{
    LinuxBackend, LiveWallpaperPlugin, WallpaperDisplayMode, WallpaperTargetMonitor,
};
use fluid::{FluidPlugin, SIM};

fn main() {
    let capture = std::env::var("NIMBUS_FLUX_CAPTURE").is_ok();
    // NIMBUS_FLUX_WALLPAPER=1 renders onto a Wayland wlr-layer-shell *background*
    // surface (via bevy_live_wallpaper) instead of a normal window — the scene becomes
    // a live, cursor-reactive desktop wallpaper.
    let wallpaper = std::env::var("NIMBUS_FLUX_WALLPAPER").is_ok();
    // Explicit NIMBUS_FLUX_SCENE wins; wallpaper mode defaults to the gothic "hexen"
    // dungeon (cyberpunk stays reachable via NIMBUS_FLUX_SCENE=cyberpunk).
    let scene = std::env::var("NIMBUS_FLUX_SCENE")
        .ok()
        .unwrap_or_else(|| if wallpaper { "hexen".into() } else { String::new() });
    // bevy_solari hardware ray-traced lighting/GI for the Solari-wired scenes
    // (experimental; needs a ray-tracing GPU). The hexen wallpaper uses RT **by
    // default**; journey is opt-in RT (NIMBUS_FLUX_RT=1) until its denoiser is wired,
    // so it defaults to the cleaner raster path even as a wallpaper. NIMBUS_FLUX_RT=0
    // forces raster; =1 forces RT in a windowed run. Other scenes ignore it.
    let rt = (scene == "hexen" || scene == "journey")
        && match std::env::var("NIMBUS_FLUX_RT").ok().as_deref() {
            Some("0") | Some("false") | Some("off") => false,
            Some(_) => true,
            None => wallpaper && scene == "hexen", // hexen wallpaper RT; journey raster
        };

    // In wallpaper mode there is no primary window — the layer-shell surface is owned
    // by LiveWallpaperPlugin, and the app must not exit when "no window" closes.
    let window_plugin = if wallpaper {
        WindowPlugin {
            primary_window: None,
            exit_condition: bevy::window::ExitCondition::DontExit,
            ..default()
        }
    } else {
        WindowPlugin {
            primary_window: Some(Window {
                title: "Nimbus Flux".into(),
                resolution: (SIM.x, SIM.y).into(),
                present_mode: PresentMode::AutoVsync,
                ..default()
            }),
            ..default()
        }
    };

    let mut app = App::new();
    app.insert_resource(ClearColor(Color::BLACK))
        .insert_resource(scene_cyberpunk::WallpaperMode(wallpaper));
    // DLSS's init plugin (pulled in by DefaultPlugins under --features dlss) requires this
    // resource before RenderPlugin or it panics — so insert it unconditionally when the
    // feature is built. It only registers DLSS Vulkan support; actual denoising happens
    // only on the RT camera (which adds the Dlss component). Harmless for other scenes.
    #[cfg(feature = "dlss")]
    app.insert_resource(bevy::anti_alias::dlss::DlssProjectId(bevy::asset::uuid::uuid!(
        "b9e2f1a4-3c5d-4e7f-8a1b-2c3d4e5f6a7b"
    )));
    app.add_plugins(DefaultPlugins.set(window_plugin).set(ImagePlugin::default_linear()))
        .add_plugins(FrameTimeDiagnosticsPlugin::default());

    // Ray-traced lighting: SolariPlugins must be added early (it requests the
    // ray-tracing wgpu features before the render device is created).
    if rt {
        app.add_plugins(bevy::solari::prelude::SolariPlugins);
    }

    if wallpaper {
        app.add_plugins(LiveWallpaperPlugin {
            target_monitor: WallpaperTargetMonitor::Index(0),
            display_mode: WallpaperDisplayMode::Wallpaper,
            linux_backend: LinuxBackend::Wayland,
        });
    }

    // Scene selector: gothic dungeon or cyberpunk city showpiece, else the fluid sim.
    match scene.as_str() {
        "hexen" => {
            app.add_plugins(scene_hexen::HexenPlugin { rt });
        }
        "journey" => {
            app.add_plugins(scene_journey::JourneyPlugin { rt });
        }
        "cyberpunk" => {
            app.add_plugins(scene_cyberpunk::CyberpunkPlugin);
        }
        _ => {
            app.add_plugins(FluidPlugin).add_plugins(hero::HeroPlugin);
        }
    }

    // Capture mode needs a primary window to screenshot; no-op in wallpaper mode.
    if capture && !wallpaper {
        app.add_systems(Update, capture_and_exit);
    }

    app.run();
}

/// Capture-mode lifecycle: snapshot a frame, log FPS, exit. Gated on the env var.
fn capture_and_exit(
    time: Res<Time>,
    diagnostics: Res<DiagnosticsStore>,
    mut commands: Commands,
    mut state: Local<u8>,
) {
    let t = time.elapsed_secs();
    if *state == 0 && t > 4.0 {
        commands
            .spawn(Screenshot::primary_window())
            .observe(save_to_disk("/tmp/nimbus-flux-frame.png"));
        *state = 1;
    }
    if *state == 1 && t > 6.0 {
        if let Some(fps) = diagnostics.get(&FrameTimeDiagnosticsPlugin::FPS) {
            if let Some(avg) = fps.average() {
                info!("NIMBUS_FLUX_FPS avg={avg:.1}");
            }
        }
        // Capture mode is a one-shot check; the snapshot was saved ~2s ago and is
        // flushed by now, so a hard exit is safe and avoids the event-writer API.
        std::process::exit(0);
    }
}
