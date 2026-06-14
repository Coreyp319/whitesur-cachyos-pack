//! Layer-10 cyberpunk scene mode — a real-time 3D neon-city flythrough showpiece.
//!
//! Activated with `NIMBUS_FLUX_SCENE=cyberpunk` (otherwise the fluid sim + hero run).
//! Composes two Blender-authored GLBs — `cyber_city.glb` (neon towers, an emissive
//! floor grid, holo signs) and `cyber_core.glb` (the glowing datacore) — under one
//! HDR + bloom camera with exponential distance fog and a few neon point lights,
//! flown along the central street on a slow dolly. This is the asset-driven sibling
//! of the procedural fluid sim: Blender → glTF → bevy/wgpu, lit and animated live.

use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::pbr::{DistanceFog, FogFalloff};
use bevy::post_process::bloom::Bloom; // bevy 0.18 moved bloom out of core_pipeline
use bevy::prelude::*;
use bevy::render::view::Hdr; // hdr is a component in 0.18, not a Camera field
use bevy_live_wallpaper::LiveWallpaperCamera;

pub struct CyberpunkPlugin;

impl Plugin for CyberpunkPlugin {
    fn build(&self, app: &mut App) {
        // dark teal void so the horizon blends into the fog colour
        app.insert_resource(ClearColor(Color::srgb(0.008, 0.018, 0.032)))
            .init_resource::<WindowReact>()
            .add_systems(Startup, setup)
            .add_systems(Update, (poll_windows, spin_core, fly_camera).chain());
    }
}

#[derive(Component)]
struct Core;
#[derive(Component)]
struct FlyCam;

/// Set by `main()` — true when rendering onto a wlr-layer-shell wallpaper surface.
#[derive(Resource)]
pub struct WallpaperMode(pub bool);

fn setup(mut commands: Commands, assets: Res<AssetServer>, wp: Res<WallpaperMode>) {
    // HDR camera: filmic tonemap + bloom make the emissive neon glow, exponential
    // fog gives the street depth and the hazy "Night City" atmosphere.
    let cam = commands
        .spawn((
            Camera3d::default(),
            Hdr,
            Tonemapping::TonyMcMapface,
            Bloom::NATURAL,
            // per-view ambient (a Component in bevy 0.18) — a faint teal lift on matte faces
            AmbientLight {
                color: Color::srgb(0.25, 0.45, 0.7),
                brightness: 12.0,
                ..default()
            },
            DistanceFog {
                color: Color::srgb(0.014, 0.034, 0.055),
                directional_light_color: Color::srgb(0.1, 0.55, 0.75),
                directional_light_exponent: 28.0,
                falloff: FogFalloff::Exponential { density: 0.026 },
            },
            Transform::from_xyz(3.0, 3.4, 30.0).looking_at(Vec3::new(0.0, 8.0, 0.0), Vec3::Y),
            FlyCam,
        ))
        .id();
    // On a layer-shell wallpaper surface the camera must carry this marker so
    // bevy_live_wallpaper retargets its render onto the background surface.
    if wp.0 {
        commands.entity(cam).insert(LiveWallpaperCamera);
    }

    // very dim cool key — the scene is emission-driven; this just keeps the matte
    // tower faces from going pure black.
    commands.spawn((
        DirectionalLight {
            illuminance: 220.0,
            color: Color::srgb(0.55, 0.65, 0.95),
            ..default()
        },
        Transform::from_xyz(8.0, 24.0, 10.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));

    // neon pools down the street — the city is built along bevy Z, |x| < 9 is the
    // corridor, height is +Y (Blender Z → glTF Y → bevy Y).
    let neon: [(Color, Vec3); 6] = [
        (Color::srgb(0.0, 0.85, 1.0), Vec3::new(-5.5, 3.5, 14.0)),
        (Color::srgb(1.0, 0.1, 0.5), Vec3::new(5.5, 4.0, 2.0)),
        (Color::srgb(1.0, 0.9, 0.1), Vec3::new(-5.5, 5.5, -12.0)),
        (Color::srgb(0.0, 0.85, 1.0), Vec3::new(5.5, 3.5, -26.0)),
        (Color::srgb(1.0, 0.1, 0.5), Vec3::new(-5.5, 4.5, -40.0)),
        (Color::srgb(0.2, 0.95, 1.0), Vec3::new(0.0, 9.0, 0.0)), // up-light on the core
    ];
    for (color, pos) in neon {
        commands.spawn((
            PointLight {
                color,
                intensity: 320_000.0,
                range: 45.0,
                shadows_enabled: false,
                ..default()
            },
            Transform::from_translation(pos),
        ));
    }

    // the city environment
    commands.spawn((
        SceneRoot(assets.load(GltfAssetLabel::Scene(0).from_asset("cyber_city.glb"))),
        Transform::IDENTITY,
    ));
    // the datacore centerpiece, lifted to eye level and scaled up
    commands.spawn((
        SceneRoot(assets.load(GltfAssetLabel::Scene(0).from_asset("cyber_core.glb"))),
        Transform::from_xyz(0.0, 7.0, 0.0).with_scale(Vec3::splat(3.2)),
        Core,
    ));
}

fn spin_core(time: Res<Time>, mut q: Query<&mut Transform, With<Core>>) {
    for mut t in &mut q {
        t.rotate_y(0.35 * time.delta_secs());
    }
}

/// Smooth, loop-free dolly: oscillate down the street along Z with a gentle sway and
/// bob, framing the datacore. Window-drag reactivity (`react.yaw/pitch`, already fully
/// tweened in `poll_windows`) leans the framing; it eases in and out, never jitters.
fn fly_camera(time: Res<Time>, react: Res<WindowReact>, mut q: Query<&mut Transform, With<FlyCam>>) {
    let t = time.elapsed_secs();
    for mut tr in &mut q {
        let z = (t * 0.13).cos() * 30.0;
        let x = (t * 0.27).sin() * 3.2;
        let y = 3.4 + (t * 0.2).sin() * 0.8;
        tr.translation = Vec3::new(x, y, z);
        let look_x = (react.yaw * 1.6).clamp(-6.0, 6.0);
        let look_y = (7.5 - react.pitch * 1.2).clamp(3.5, 11.5);
        tr.look_at(Vec3::new(look_x, look_y, 0.0), Vec3::Y);
    }
}

/// Window-drag reactivity, **debounced then tweened** so it can never judder. Pipeline:
/// raw window centre → low-pass (input debounce) → differentiate the *smoothed* centre
/// only while dragging → deadzone + clamp (kill jitter & snap spikes) → low-pass the
/// velocity → critically-damped spring (output). Reads the Layer-9 `windows.json`
/// bridge — the same KWin→file feed the QML aurora uses.
#[derive(Resource, Default)]
struct WindowReact {
    yaw: f32,            // smoothed camera offset (spring position)
    pitch: f32,
    yaw_v: f32,          // spring velocity (critical damping)
    pitch_v: f32,
    tgt: Vec2,           // low-passed velocity target the spring chases
    center_smooth: Vec2, // low-passed window centre — the input debounce
    prev_smooth: Vec2,   // previous frame's smoothed centre (for the derivative)
    seeded: bool,        // has center_smooth been initialised?
    moving: bool,        // is a window currently being dragged?
}

/// Semi-implicit critically-damped spring step — no overshoot, frame-rate independent.
fn spring(x: &mut f32, v: &mut f32, target: f32, omega: f32, dt: f32) {
    let accel = omega * omega * (target - *x) - 2.0 * omega * *v;
    *v += accel * dt;
    *x += *v * dt;
}

fn poll_windows(time: Res<Time>, react: ResMut<WindowReact>) {
    let dt = time.delta_secs().clamp(1e-4, 0.1); // clamp for spring/derivative stability
    let react = react.into_inner(); // deref once so the disjoint field borrows below are legal

    let (raw, moving) = match read_active_center() {
        Some((c, m)) => (Some(c), m),
        None => (None, react.moving),
    };
    react.moving = moving;

    // input debounce: low-pass the raw centre; on a big jump (focus switch / tiling
    // snap, not a drag) re-seat instead of differentiating it into a velocity spike.
    if let Some(c) = raw {
        if react.seeded && (c - react.center_smooth).length() < 0.5 {
            let a = 1.0 - (-dt / 0.06).exp();
            react.center_smooth += (c - react.center_smooth) * a;
        } else {
            react.center_smooth = c;
            react.prev_smooth = c; // no velocity across a teleport
            react.seeded = true;
        }
    }

    // velocity = derivative of the *smoothed* centre, only while a drag is in progress
    let mut vel = if moving {
        (react.center_smooth - react.prev_smooth) / dt
    } else {
        Vec2::ZERO
    };
    react.prev_smooth = react.center_smooth;
    if vel.length() < 0.08 {
        vel = Vec2::ZERO; // deadzone: ignore sub-threshold drift
    }
    vel = vel.clamp_length_max(3.0); // reject spikes

    // output smoothing: low-pass the velocity target, then a critically-damped spring
    let a_in = 1.0 - (-dt / 0.08).exp();
    react.tgt += (vel - react.tgt) * a_in;
    let (tx, ty) = (react.tgt.x, react.tgt.y);
    let omega = 7.0; // softer = smoother; settle ~0.5 s
    spring(&mut react.yaw, &mut react.yaw_v, tx, omega, dt);
    spring(&mut react.pitch, &mut react.pitch_v, ty, omega, dt);
}

/// Parse the window bridge file → the reactive window's normalised centre ([-1,1],
/// centre origin, +x right / +y down) and whether a window is currently being dragged.
fn read_active_center() -> Option<(Vec2, bool)> {
    let rt = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let text = std::fs::read_to_string(format!("{rt}/nimbus-aurora/windows.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let wins = v.get("wins").and_then(|x| x.as_array());

    // screen extent, for normalising pixel coordinates
    let (mut sw, mut sh) = (1.0_f64, 1.0_f64);
    if let Some(ws) = wins {
        for w in ws {
            sw = sw.max(w["x"].as_f64().unwrap_or(0.0) + w["w"].as_f64().unwrap_or(0.0));
            sh = sh.max(w["y"].as_f64().unwrap_or(0.0) + w["h"].as_f64().unwrap_or(0.0));
        }
    }
    let moving = v.get("move").map(|m| !m.is_null()).unwrap_or(false)
        || wins
            .map(|ws| ws.iter().any(|w| w["moving"].as_bool().unwrap_or(false)))
            .unwrap_or(false);
    // the window driving reactivity: the dragged one if any, else the active one
    let pick = v
        .get("move")
        .filter(|m| !m.is_null())
        .cloned()
        .or_else(|| wins.and_then(|ws| ws.iter().find(|w| w["moving"].as_bool().unwrap_or(false)).cloned()))
        .or_else(|| wins.and_then(|ws| ws.iter().find(|w| w["active"].as_bool().unwrap_or(false)).cloned()))?;
    let cx = (pick["x"].as_f64().unwrap_or(0.0) + pick["w"].as_f64().unwrap_or(0.0) / 2.0) / sw;
    let cy = (pick["y"].as_f64().unwrap_or(0.0) + pick["h"].as_f64().unwrap_or(0.0) / 2.0) / sh;
    Some((Vec2::new((cx as f32 - 0.5) * 2.0, (cy as f32 - 0.5) * 2.0), moving))
}
