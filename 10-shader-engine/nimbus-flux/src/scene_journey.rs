//! Layer-10 "journey" scene — the dreaming-phase scene composer.
//!
//! Activated with `NIMBUS_FLUX_SCENE=journey`. Renders an ordered, append-only
//! sequence of **leg manifests** (`journey/leg-NNN.json`) as one continuous,
//! seamless corridor the camera travels forever. Each leg is authored in its own
//! local frame; **portal chaining** aligns each leg's entry to the previous leg's
//! exit so the joins are invisible (`portal_affine` / problem A in the handoff).
//!
//! This is the runtime half of the "dreaming" design: a Layer-6 local model will
//! eventually emit these JSON manifests (referencing only a vetted CC0 catalog),
//! and this already-compiled composer instantiates geometry / props / lights from
//! them at runtime — no compiling AI output. The legs are **hand-authored** for now.
//!
//! Camera / playback (resolved policy — SCENE-COMPOSITION.md "Camera / playback
//! policy"): **wake at the frontier** (the newest leg) + a **daily recap**. Forward
//! travel = toward the newest leg. Each session the camera spawns ≈ one leg behind the
//! newest entry and slow-dollies forward through it, easing out to a hover at the
//! frontier exit — **never loops or reverses**. On the first wake of a day it first
//! fast-travels a recap of the last few legs, then settles. Only a **window** of legs
//! is kept live (streamed in/out by camera position) so GPU cost stays bounded no
//! matter how long the journey grows (problem C).
//!
//! Reuses the on-hand `hexen` CC0 asset set (stone textures + glTF props under
//! `assets/hexen/`), so it renders without any extra download. A future catalog
//! (handoff problem H) will generalise the asset paths.
//!
//! Robustness contract: a missing/invalid leg is skipped + logged, never crashes the
//! wallpaper. An empty journey still runs (camera + atmosphere, no geometry).

use std::collections::HashSet;
use std::f32::consts::FRAC_PI_2;
use std::path::PathBuf;

use bevy::camera::{CameraMainTextureUsages, Exposure};
use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::image::{ImageAddressMode, ImageLoaderSettings, ImageSampler, ImageSamplerDescriptor};
use bevy::light::{FogVolume, VolumetricFog, VolumetricLight};
use bevy::math::{Affine2, Affine3A};
use bevy::pbr::{DistanceFog, FogFalloff, ParallaxMappingMethod, ScreenSpaceAmbientOcclusion};
use bevy::post_process::bloom::Bloom;
use bevy::prelude::*;
use bevy::render::render_resource::TextureUsages;
use bevy::render::view::Hdr;
use bevy::solari::prelude::{RaytracingMesh3d, SolariLighting};
use bevy_live_wallpaper::LiveWallpaperCamera;
use serde::Deserialize;

use crate::window_react::{WindowReact, WindowReactPlugin};

// ============================================================================
// Manifest schema (serde) — the data the composer reads. Kept close to the
// SCENE-COMPOSITION.md sketch; hardened with defaults so a terse leg still loads.
// ============================================================================

/// One leg of the journey. `leg-000` is the hand-authored seed; each later leg
/// continues from its predecessor's exit (`seed_from`) and is authored in its own
/// local frame with the entry portal near the local origin facing −Z (travel dir).
#[derive(Deserialize, Clone)]
struct LegManifest {
    id: String,
    // carried for the evolution + provenance work (steps 4+); not yet read.
    #[serde(default)]
    #[allow(dead_code)]
    seed_from: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    day: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    theme: Theme,
    entry: Portal,
    exit: Portal,
    #[serde(default)]
    geometry: Vec<Geometry>,
    #[serde(default)]
    props: Vec<Prop>,
    #[serde(default)]
    lights: Vec<LightSpec>,
    #[serde(default)]
    atmosphere: Atmosphere,
    /// Free-form provenance (signals/model notes) — carried, not interpreted here.
    #[serde(default)]
    #[allow(dead_code)]
    provenance: serde_json::Value,
}

#[derive(Deserialize, Clone, Default)]
struct Theme {
    #[serde(default)]
    #[allow(dead_code)]
    palette: Vec<String>,
    #[serde(default)]
    #[allow(dead_code)]
    motif: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    mood: Option<String>,
}

/// A portal frame: a point + travel direction (`forward`) + `up`, plus the aperture
/// (width × height) the join must match. The composer treats `forward` as the camera's
/// −Z (bevy-natural), so a portal is oriented like a camera looking down the corridor.
#[derive(Deserialize, Clone)]
struct Portal {
    at: [f32; 3],
    forward: [f32; 3],
    #[serde(default = "up_y")]
    up: [f32; 3],
    #[serde(default = "aperture_default")]
    aperture: [f32; 2],
}

/// Parameterised architecture the composer can build. The "Lego set" the model
/// arranges (handoff problem B). MVP ships `corridor`; room/stair/bridge/etc. slot
/// in here later (each must expose a matching entry+exit portal).
#[derive(Deserialize, Clone)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum Geometry {
    Corridor(Corridor),
}

#[derive(Deserialize, Clone)]
struct Corridor {
    length: f32,
    width: f32,
    height: f32,
    floor: String,
    ceiling: String,
    wall: String,
    trim: String,
    #[serde(default = "tru")]
    columns: bool,
    #[serde(default = "col_spacing_default")]
    col_spacing: f32,
    /// Warm torch tint; drifts per leg to make "related but progressing" legible.
    #[serde(default = "torch_warm")]
    torch_color: [f32; 3],
}

#[derive(Deserialize, Clone)]
struct Prop {
    /// Poly Haven model id (matches `assets/hexen/models/<model>/<model>_2k.gltf`).
    model: String,
    pos: [f32; 3],
    #[serde(default)]
    rot_y: f32,
    #[serde(default = "one")]
    scale: f32,
}

/// A special light beyond the corridor's auto-generated torches (e.g. a focal key
/// light, a prop's inner glow).
#[derive(Deserialize, Clone)]
struct LightSpec {
    #[serde(default)]
    #[allow(dead_code)]
    kind: Option<String>,
    pos: [f32; 3],
    color: [f32; 3],
    intensity: f32,
    #[serde(default = "light_range")]
    range: f32,
    #[serde(default)]
    shadows: bool,
    #[serde(default)]
    volumetric: bool,
}

/// Per-leg atmosphere. The global camera atmosphere (clear / distance fog / ambient /
/// moonlight) currently comes from the **newest** leg (the frontier the camera lives
/// near); per-leg blending across the seam is problem J (future). The per-leg `fog_*`
/// here still drive each leg's own `FogVolume`, so legs vary their local haze.
#[derive(Deserialize, Clone)]
struct Atmosphere {
    #[serde(default = "clear_default")]
    clear: [f32; 3],
    #[serde(default = "fog_density_default")]
    fog_density: f32,
    #[serde(default = "fog_color_default")]
    fog_color: [f32; 3],
    #[serde(default = "ambient_default")]
    ambient: [f32; 3],
    #[serde(default = "ambient_brightness_default")]
    ambient_brightness: f32,
    #[serde(default = "moon_dir_default")]
    moon_dir: [f32; 3],
    #[serde(default = "moon_color_default")]
    moon_color: [f32; 3],
    #[serde(default = "moon_illuminance_default")]
    moon_illuminance: f32,
    #[serde(default = "fog_volume_density_default")]
    fog_volume_density: f32,
}

impl Default for Atmosphere {
    fn default() -> Self {
        Self {
            clear: clear_default(),
            fog_density: fog_density_default(),
            fog_color: fog_color_default(),
            ambient: ambient_default(),
            ambient_brightness: ambient_brightness_default(),
            moon_dir: moon_dir_default(),
            moon_color: moon_color_default(),
            moon_illuminance: moon_illuminance_default(),
            fog_volume_density: fog_volume_density_default(),
        }
    }
}

// serde default helpers (free fns — serde wants a fn path)
fn up_y() -> [f32; 3] { [0.0, 1.0, 0.0] }
fn aperture_default() -> [f32; 2] { [6.0, 5.2] }
fn tru() -> bool { true }
fn one() -> f32 { 1.0 }
fn col_spacing_default() -> f32 { 7.5 }
fn torch_warm() -> [f32; 3] { [1.0, 0.55, 0.22] }
fn light_range() -> f32 { 8.0 }
fn clear_default() -> [f32; 3] { [0.018, 0.013, 0.010] }
fn fog_density_default() -> f32 { 0.007 }
fn fog_color_default() -> [f32; 3] { [0.020, 0.016, 0.013] }
fn ambient_default() -> [f32; 3] { [0.42, 0.52, 0.85] }
fn ambient_brightness_default() -> f32 { 42.0 }
fn moon_dir_default() -> [f32; 3] { [0.15, -0.9, -0.4] }
fn moon_color_default() -> [f32; 3] { [0.55, 0.65, 0.95] }
fn moon_illuminance_default() -> f32 { 850.0 }
fn fog_volume_density_default() -> f32 { 0.028 }

// ============================================================================
// Plugin + resources + components
// ============================================================================

pub struct JourneyPlugin {
    /// Ray-traced lighting via bevy_solari (NIMBUS_FLUX_RT=1). Opt-in for journey
    /// until the DLSS denoiser is wired (the raw Solari path is grainy); the wallpaper
    /// default for this scene is the cleaner raster path.
    pub rt: bool,
}

#[derive(Resource, Clone, Copy)]
struct RtMode(bool);

/// A leg placed in world space: its manifest, world transform, and the arc-length
/// span `[entry_dist, exit_dist]` it occupies along the journey spine.
struct LegPlacement {
    manifest: LegManifest,
    world: Affine3A,
    entry_dist: f32,
    exit_dist: f32,
}

/// The static, fully-chained journey (built once at startup). Geometry is **not**
/// spawned here — `stream_legs` instantiates a moving window of it.
#[derive(Resource)]
struct Journey {
    legs: Vec<LegPlacement>,
    spine: Vec<Vec3>, // world-space portal centres in order (entry₀, exit₀, exit₁, …)
    total: f32,       // total arc length (0 at leg-000 entry → total at the frontier exit)
    eye: f32,         // camera eye height
    typical_leg: f32, // mean leg length — sizes the streaming window + default knobs
    rt: bool,
}

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Recap,
    Drift,
}

/// Live camera/playback state, advanced each frame.
#[derive(Resource)]
struct JourneyPlayback {
    progress: f32, // current arc-length position of the camera (monotonic forward)
    speed: f32,    // drift dolly units/s
    recap_legs: usize,
    reduced_motion: bool,
    phase: Phase,
    recap_t: f32,
    recap_dur: f32,
    recap_from: f32,
    recap_to: f32,
    hover_target: f32, // ease-out and hold here (near the frontier exit)
    today: String,
    persist: bool,                // write state.json (off for capture/park/leg-override)
    spawn_all: bool,              // park-without-leg → keep every leg live for the still
    park: Option<[f32; 6]>,       // NIMBUS_FLUX_JOURNEY_CAM — fix the camera entirely
}

/// Which leg indices currently have entities spawned (the live window).
#[derive(Resource, Default)]
struct SpawnedLegs(HashSet<usize>);

#[derive(Component)]
struct JourneyCam;

/// Tags every entity belonging to leg `idx` so the streaming pass can despawn legs
/// the camera has left behind.
#[derive(Component)]
struct LegMember(usize);

/// A flickering torch; `base` is its calm intensity, `phase` decorrelates the flicker.
#[derive(Component)]
struct Torch {
    base: f32,
    phase: f32,
}

impl Plugin for JourneyPlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(RtMode(self.rt))
            .init_resource::<SpawnedLegs>()
            .add_plugins(WindowReactPlugin)
            .add_systems(Startup, setup)
            .add_systems(Update, (stream_legs, drive_camera, flicker_torches, persist_state));
        if self.rt {
            app.add_systems(Update, register_raytracing_meshes);
        }
    }
}

// ============================================================================
// Setup: load manifests, chain portals, place the camera (legs stream in later)
// ============================================================================

fn setup(mut commands: Commands, rt_mode: Res<RtMode>) {
    let rt = rt_mode.0;
    let dir = journey_dir();
    let manifests = load_legs(&dir);
    info!("journey: loaded {} leg(s) from {:?}", manifests.len(), dir);
    if manifests.is_empty() {
        error!("journey: no valid legs in {:?} — rendering atmosphere only", dir);
    }

    // ---- chain every leg into world space + accumulate the spine arc-length.
    //   world(N) = world(N-1) · exit_affine(N-1) · entry_affine(N)⁻¹
    // leg 0 is the anchor (identity). Aligning each entry to the previous exit makes
    // the joins seamless (problem A).
    let mut placements: Vec<LegPlacement> = Vec::new();
    let mut spine: Vec<Vec3> = Vec::new();
    let mut world = Affine3A::IDENTITY;
    let mut prev: Option<(Affine3A, Portal)> = None;
    let mut cum = 0.0_f32;

    for (i, leg) in manifests.into_iter().enumerate() {
        if let Some((prev_world, prev_exit)) = &prev {
            world = *prev_world * portal_affine(prev_exit) * portal_affine(&leg.entry).inverse();
            // seam self-validation (seed of the problem-A guardrails)
            let a = prev_world.transform_point3(Vec3::from(prev_exit.at));
            let b = world.transform_point3(Vec3::from(leg.entry.at));
            if a.distance(b) > 1e-3 {
                warn!("journey: seam → {} misaligned by {:.4} m", leg.id, a.distance(b));
            }
            if (Vec2::from(prev_exit.aperture) - Vec2::from(leg.entry.aperture)).length() > 0.05 {
                warn!("journey: seam → {} aperture mismatch", leg.id);
            }
        }
        let entry_c = world.transform_point3(Vec3::from(leg.entry.at));
        let exit_c = world.transform_point3(Vec3::from(leg.exit.at));
        if i == 0 {
            spine.push(entry_c);
        }
        let entry_dist = cum;
        cum += entry_c.distance(exit_c);
        let exit_dist = cum;
        spine.push(exit_c);

        let exit_portal = leg.exit.clone();
        placements.push(LegPlacement { manifest: leg, world, entry_dist, exit_dist });
        prev = Some((world, exit_portal));
    }
    let total = cum;
    let n = placements.len();
    let newest = n.saturating_sub(1);
    let eye = 1.7_f32;
    let typical_leg = if n > 0 { (total / n as f32).max(1.0) } else { 48.0 };

    // ---- global atmosphere from the frontier (newest) leg.
    let atmos = placements.last().map(|p| p.manifest.atmosphere.clone()).unwrap_or_default();
    commands.insert_resource(ClearColor(rgb(atmos.clear)));

    // ---- playback knobs (env overrides, sane defaults). Slow dolly: ~one leg / 25 min.
    let speed = env_f32("NIMBUS_FLUX_JOURNEY_SPEED").unwrap_or(typical_leg / (25.0 * 60.0));
    let backoff = env_f32("NIMBUS_FLUX_BACKOFF").unwrap_or(typical_leg * 0.5);
    let recap_legs = env_usize("NIMBUS_FLUX_RECAP_LEGS").unwrap_or(3).max(1);
    let recap_dur = env_f32("NIMBUS_FLUX_RECAP_DUR").unwrap_or(8.0);
    let reduced_motion = env_truthy("NIMBUS_FLUX_REDUCED_MOTION");
    let park = std::env::var("NIMBUS_FLUX_JOURNEY_CAM").ok().and_then(parse6);
    let leg_override = env_usize("NIMBUS_FLUX_JOURNEY_LEG");
    let capture = std::env::var("NIMBUS_FLUX_CAPTURE").is_ok();

    // wake position: BACKOFF behind the frontier entry (i.e. back in leg N-1); the hover
    // sits just short of the very end so the camera looks out through the last arch.
    let frontier_entry = placements.get(newest).map(|p| p.entry_dist).unwrap_or(0.0);
    let wake_start = (frontier_entry - backoff).max(0.0);
    let hover_target = (total - 2.0).max(wake_start);

    // ---- decide the opening: deterministic leg-override, else daily recap on the first
    // wake of the day, else resume the slow-drift from saved progress.
    let (saved_recap, saved_progress) = read_state();
    let today = today_string();
    let first_wake = saved_recap.as_deref() != Some(today.as_str());

    let mut phase = Phase::Drift;
    let mut progress = wake_start;
    let mut recap_from = 0.0;
    let mut recap_to = 0.0;

    if let Some(li) = leg_override {
        // deterministic: spawn just inside leg `li` for a capture of that handoff
        let li = li.min(newest);
        progress = placements.get(li).map(|p| p.entry_dist + 1.0).unwrap_or(0.0);
    } else if first_wake && !reduced_motion && n >= 2 {
        // fast-travel recap forward through the last `recap_legs` legs, then settle
        let from_idx = (newest + 1).saturating_sub(recap_legs).min(newest);
        recap_from = placements[from_idx].entry_dist;
        recap_to = wake_start;
        if recap_from + 1.0 < recap_to {
            phase = Phase::Recap;
            progress = recap_from;
        }
    } else if !first_wake {
        // same-day relaunch: resume where we left off (skip the recap)
        progress = saved_progress.clamp(0.0, hover_target);
    }

    let persist = park.is_none() && leg_override.is_none() && !capture;
    let spawn_all = park.is_some() && leg_override.is_none();

    // ---- camera: HDR + filmic tonemap + bloom; raster adds SSAO (windowed only), RT
    // swaps in Solari traced GI + soft shadows. Mirrors the hexen camera so both read
    // the same. Initial pose from the spine; `drive_camera` overrides each frame.
    let (cp, _) = sample_spine(&spine, progress);
    let (ca, _) = sample_spine(&spine, (progress + 4.0).min(total));
    let mut cam = commands.spawn((
        Camera3d::default(),
        Hdr,
        Tonemapping::TonyMcMapface,
        Bloom::NATURAL,
        Msaa::Off, // required by both SSAO and Solari
        AmbientLight {
            color: rgb(atmos.ambient),
            brightness: atmos.ambient_brightness,
            ..default()
        },
        VolumetricFog { ambient_intensity: 0.12, jitter: 0.5, ..default() },
        DistanceFog {
            color: rgb(atmos.fog_color),
            directional_light_color: Color::srgb(0.9, 0.55, 0.25),
            directional_light_exponent: 18.0,
            falloff: FogFalloff::Exponential { density: atmos.fog_density },
        },
        Transform::from_xyz(cp.x, eye, cp.z).looking_at(Vec3::new(ca.x, eye - 0.1, ca.z), Vec3::Y),
        JourneyCam,
        LiveWallpaperCamera, // inert unless LiveWallpaperPlugin is active (wallpaper mode)
    ));
    if rt {
        cam.insert((
            SolariLighting::default(),
            CameraMainTextureUsages::default().with(TextureUsages::STORAGE_BINDING),
            Exposure { ev100: 6.5 },
        ));
    } else if std::env::var("NIMBUS_FLUX_WALLPAPER").is_err() {
        // SSAO panics under the layer-shell surface (1×1 mip) — windowed only.
        cam.insert(ScreenSpaceAmbientOcclusion::default());
    }

    // ---- global moonlight key (cool complement to the warm torches).
    let moon_dir = Vec3::from(atmos.moon_dir).normalize_or_zero();
    commands.spawn((
        DirectionalLight {
            illuminance: if rt { atmos.moon_illuminance * 8.0 } else { atmos.moon_illuminance },
            color: rgb(atmos.moon_color),
            shadows_enabled: true,
            ..default()
        },
        VolumetricLight,
        Transform::from_xyz(0.0, 12.0, 0.0)
            .looking_to(if moon_dir == Vec3::ZERO { Vec3::NEG_Y } else { moon_dir }, Vec3::Y),
    ));

    if persist {
        // stamp last_recap=today right away so a mid-day relaunch doesn't replay the recap
        write_state(&today, progress);
    }

    commands.insert_resource(JourneyPlayback {
        progress,
        speed,
        recap_legs,
        reduced_motion,
        phase,
        recap_t: 0.0,
        recap_dur,
        recap_from,
        recap_to,
        hover_target,
        today,
        persist,
        spawn_all,
        park,
    });
    commands.insert_resource(Journey { legs: placements, spine, total, eye, typical_leg, rt });
}

/// Compose a portal's local-frame transform: a rigid frame whose −Z (bevy-forward)
/// points along `forward`, located at `at`.
fn portal_affine(p: &Portal) -> Affine3A {
    let fwd = Vec3::from(p.forward).normalize_or_zero();
    let fwd = if fwd == Vec3::ZERO { Vec3::NEG_Z } else { fwd };
    Transform::from_translation(Vec3::from(p.at))
        .looking_to(fwd, Vec3::from(p.up))
        .compute_affine()
}

/// Bake a leg-local transform into world space (the leg frames are rigid, no scale,
/// so non-uniform child scale survives the compose).
fn place(world: &Affine3A, local: Transform) -> Transform {
    Transform::from_matrix(Mat4::from(*world) * local.to_matrix())
}

/// Indices of legs whose arc-span `(entry_dist, exit_dist)` overlaps the live window
/// `[progress - behind, progress + ahead]`. Pure (no ECS) so the windowing — the thing
/// that keeps entity/VRAM cost bounded — is verifiable headless, where NVIDIA+Wayland
/// windowed captures are flaky.
fn window_indices(spans: &[(f32, f32)], progress: f32, behind: f32, ahead: f32) -> Vec<usize> {
    let lo = progress - behind;
    let hi = progress + ahead;
    spans
        .iter()
        .enumerate()
        .filter(|(_, (entry, exit))| *exit >= lo && *entry <= hi)
        .map(|(i, _)| i)
        .collect()
}

// ============================================================================
// Streaming: keep only a window of legs live (spawn ahead, despawn behind)
// ============================================================================

/// Spawn legs entering the live window and despawn legs leaving it, so entity/VRAM
/// cost stays bounded however long the journey grows (problem C). The window is sized
/// to ~one leg ahead/behind the camera; during the recap it widens to cover the legs
/// being flown through. Park-without-leg keeps every leg live for a deterministic still.
fn stream_legs(
    mut commands: Commands,
    journey: Res<Journey>,
    playback: Res<JourneyPlayback>,
    mut spawned: ResMut<SpawnedLegs>,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    assets: Res<AssetServer>,
    members: Query<(Entity, &LegMember)>,
) {
    // desired live set
    let desired: HashSet<usize> = if playback.spawn_all {
        (0..journey.legs.len()).collect()
    } else {
        let behind = if playback.phase == Phase::Recap {
            (playback.recap_legs as f32 + 1.0) * journey.typical_leg
        } else {
            journey.typical_leg * 1.2
        };
        let spans: Vec<(f32, f32)> = journey.legs.iter().map(|p| (p.entry_dist, p.exit_dist)).collect();
        window_indices(&spans, playback.progress, behind, journey.typical_leg * 1.2)
            .into_iter()
            .collect()
    };

    if desired == spawned.0 {
        return;
    }

    // spawn newcomers
    for &i in desired.iter() {
        if !spawned.0.contains(&i) {
            spawn_leg(&mut commands, &mut meshes, &mut materials, &assets, &journey.legs[i], i, journey.rt);
        }
    }
    // despawn legs left behind
    let drop: HashSet<usize> = spawned.0.difference(&desired).copied().collect();
    if !drop.is_empty() {
        for (e, m) in &members {
            if drop.contains(&m.0) {
                commands.entity(e).despawn();
            }
        }
    }
    spawned.0 = desired;
    let mut live: Vec<usize> = spawned.0.iter().copied().collect();
    live.sort_unstable();
    info!("journey: live legs {:?} (of {})", live, journey.legs.len());
}

/// Instantiate one leg's geometry / props / lights / fog into world space.
fn spawn_leg(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    assets: &AssetServer,
    p: &LegPlacement,
    idx: usize,
    rt: bool,
) {
    let leg = &p.manifest;
    let world = &p.world;

    // architecture
    let mut span = (6.0_f32, 5.2_f32, 48.0_f32); // (w, h, len) fallback for the fog volume
    for g in &leg.geometry {
        match g {
            Geometry::Corridor(c) => {
                span = (c.width, c.height, c.length);
                build_corridor(commands, meshes, materials, assets, c, world, idx, rt);
            }
        }
    }

    // props (Poly Haven CC0 glTF, reusing the on-hand hexen set)
    for prop in &leg.props {
        let local = Transform::from_xyz(prop.pos[0], prop.pos[1], prop.pos[2])
            .with_scale(Vec3::splat(prop.scale))
            .with_rotation(Quat::from_rotation_y(prop.rot_y));
        commands.spawn((
            SceneRoot(assets.load(
                GltfAssetLabel::Scene(0).from_asset(format!("hexen/models/{0}/{0}_2k.gltf", prop.model)),
            )),
            place(world, local),
            LegMember(idx),
        ));
    }

    // special lights (key / glow), on top of the corridor's auto torches
    for l in &leg.lights {
        let intensity = if rt { l.intensity * 3.0 } else { l.intensity };
        let mut e = commands.spawn((
            PointLight {
                color: rgb(l.color),
                intensity,
                range: l.range,
                shadows_enabled: l.shadows,
                ..default()
            },
            place(world, Transform::from_xyz(l.pos[0], l.pos[1], l.pos[2])),
            LegMember(idx),
        ));
        if l.volumetric {
            e.insert(VolumetricLight);
        }
    }

    // per-leg fog volume sized to the corridor → each leg carries its own haze tint
    let (w, h, len) = span;
    commands.spawn((
        FogVolume {
            fog_color: rgb(leg.atmosphere.fog_color),
            density_factor: leg.atmosphere.fog_volume_density,
            scattering: 0.6,
            ..default()
        },
        place(world, Transform::from_xyz(0.0, h / 2.0, -len / 2.0).with_scale(Vec3::new(w, h, len))),
        LegMember(idx),
    ));
}

/// Build a corridor segment in its local frame (entry at the origin, running toward
/// −Z to `exit` at z = −length): floor / ceiling / walls, an entry archway that frames
/// the seam, a column+rib arcade rhythm, and an alternating torch per bay. All baked
/// into `world`. Material/parallax recipe matches `scene_hexen` (kept local so this
/// file never has to edit the concurrently-owned hexen module).
#[allow(clippy::too_many_arguments)]
fn build_corridor(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    assets: &AssetServer,
    c: &Corridor,
    world: &Affine3A,
    idx: usize,
    rt: bool,
) {
    let (w, h, len) = (c.width, c.height, c.length);

    let floor_mat = stone_material(materials, assets, &c.floor, Vec2::new(w / 2.0, len / 2.0), 0.45, 0.03);
    let ceil_mat = stone_material(materials, assets, &c.ceiling, Vec2::new(w / 3.0, len / 3.0), 0.85, 0.025);
    let wall_mat = stone_material(materials, assets, &c.wall, Vec2::new(len / 1.7, h / 1.7), 0.7, 0.045);
    let trim_mat = stone_material(materials, assets, &c.trim, Vec2::new(1.0, 2.0), 0.8, 0.0);

    let mid_z = -len / 2.0;

    // floor & ceiling
    commands.spawn((
        Mesh3d(meshes.add(rect(w, len))),
        MeshMaterial3d(floor_mat),
        place(world, Transform::from_xyz(0.0, 0.0, mid_z).with_rotation(Quat::from_rotation_x(-FRAC_PI_2))),
        LegMember(idx),
    ));
    commands.spawn((
        Mesh3d(meshes.add(rect(w, len))),
        MeshMaterial3d(ceil_mat),
        place(world, Transform::from_xyz(0.0, h, mid_z).with_rotation(Quat::from_rotation_x(FRAC_PI_2))),
        LegMember(idx),
    ));

    // side walls (faces rotated to point inward)
    let wall_mesh = meshes.add(rect(len, h));
    commands.spawn((
        Mesh3d(wall_mesh.clone()),
        MeshMaterial3d(wall_mat.clone()),
        place(world, Transform::from_xyz(-w / 2.0, h / 2.0, mid_z).with_rotation(Quat::from_rotation_y(FRAC_PI_2))),
        LegMember(idx),
    ));
    commands.spawn((
        Mesh3d(wall_mesh),
        MeshMaterial3d(wall_mat),
        place(world, Transform::from_xyz(w / 2.0, h / 2.0, mid_z).with_rotation(Quat::from_rotation_y(-FRAC_PI_2))),
        LegMember(idx),
    ));

    // entry archway at local z≈0 — exactly one arch stands at any seam (this leg's),
    // reading as an intentional threshold that hides the per-leg texture reset.
    let pier = meshes.add(block(0.35, h, 0.5));
    for side in [-1.0_f32, 1.0] {
        commands.spawn((
            Mesh3d(pier.clone()),
            MeshMaterial3d(trim_mat.clone()),
            place(world, Transform::from_xyz(side * (w / 2.0 - 0.18), h / 2.0, 0.0)),
            LegMember(idx),
        ));
    }
    commands.spawn((
        Mesh3d(meshes.add(block(w, 0.55, 0.5))),
        MeshMaterial3d(trim_mat.clone()),
        place(world, Transform::from_xyz(0.0, h - 0.3, 0.0)),
        LegMember(idx),
    ));

    // column + rib arcade + a torch per bay (alternating sides)
    if c.columns {
        let col_mesh = meshes.add(block(0.7, h, 0.7));
        let rib_mesh = meshes.add(block(w + 0.5, 0.6, 0.7));
        let mut z = -c.col_spacing;
        let mut bay = 0;
        while z > -len + 1.0 {
            for side in [-1.0_f32, 1.0] {
                commands.spawn((
                    Mesh3d(col_mesh.clone()),
                    MeshMaterial3d(trim_mat.clone()),
                    place(world, Transform::from_xyz(side * (w / 2.0 - 0.3), h / 2.0, z)),
                    LegMember(idx),
                ));
            }
            commands.spawn((
                Mesh3d(rib_mesh.clone()),
                MeshMaterial3d(trim_mat.clone()),
                place(world, Transform::from_xyz(0.0, h - 0.45, z)),
                LegMember(idx),
            ));

            let side = if bay % 2 == 0 { -1.0 } else { 1.0 };
            spawn_torch(commands, meshes, materials, world, Vec3::new(side * (w / 2.0 - 0.55), 3.1, z), c.torch_color, bay, idx, rt);

            z -= c.col_spacing;
            bay += 1;
        }
    }
}

/// A flickering torch: a warm point light + a small emissive flame the bloom pass
/// turns into a glow. Brighter in RT (Solari lights stone only from real lights).
#[allow(clippy::too_many_arguments)]
fn spawn_torch(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    world: &Affine3A,
    pos: Vec3,
    color: [f32; 3],
    bay: i32,
    idx: usize,
    rt: bool,
) {
    let base = if rt { 900_000.0 } else { 160_000.0 };
    commands.spawn((
        PointLight {
            color: rgb(color),
            intensity: base,
            range: if rt { 34.0 } else { 19.0 },
            shadows_enabled: true,
            ..default()
        },
        VolumetricLight,
        place(world, Transform::from_translation(pos)),
        Torch { base, phase: bay as f32 * 1.7 },
        LegMember(idx),
    ));
    commands.spawn((
        Mesh3d(meshes.add(Sphere::new(0.11).mesh().ico(3).unwrap())),
        MeshMaterial3d(materials.add(StandardMaterial {
            base_color: Color::BLACK,
            emissive: if rt { LinearRgba::rgb(18.0, 7.0, 2.0) } else { LinearRgba::rgb(7.0, 2.6, 0.7) },
            ..default()
        })),
        place(world, Transform::from_translation(pos)),
        LegMember(idx),
    ));
}

/// Build a `StandardMaterial` from a Poly Haven stone set (`<id>_{diff,nor_gl,arm,disp}`).
/// Same recipe as `scene_hexen::stone_material` (duplicated, not shared, to avoid editing
/// the concurrently-owned hexen module). `depth == 0` disables parallax (stretched-UV trim).
fn stone_material(
    materials: &mut Assets<StandardMaterial>,
    assets: &AssetServer,
    id: &str,
    tiles: Vec2,
    roughness: f32,
    depth: f32,
) -> Handle<StandardMaterial> {
    let base = format!("hexen/textures/{id}/{id}");
    let arm = load_tex(assets, &format!("{base}_arm_2k.jpg"), false);
    let (depth_map, parallax_depth_scale) = if depth > 0.0 {
        (Some(load_tex(assets, &format!("{base}_disp_2k.jpg"), false)), depth)
    } else {
        (None, 0.0)
    };
    materials.add(StandardMaterial {
        base_color_texture: Some(load_tex(assets, &format!("{base}_diff_2k.jpg"), true)),
        normal_map_texture: Some(load_tex(assets, &format!("{base}_nor_gl_2k.jpg"), false)),
        metallic_roughness_texture: Some(arm.clone()),
        occlusion_texture: Some(arm),
        depth_map,
        parallax_depth_scale,
        parallax_mapping_method: ParallaxMappingMethod::Relief { max_steps: 8 },
        max_parallax_layer_count: 32.0,
        perceptual_roughness: roughness,
        metallic: 1.0,
        uv_transform: Affine2::from_scale(tiles),
        ..default()
    })
}

/// Load an image with repeat addressing (tiling) and an explicit sRGB flag.
fn load_tex(assets: &AssetServer, path: &str, srgb: bool) -> Handle<Image> {
    assets.load_with_settings(path.to_string(), move |s: &mut ImageLoaderSettings| {
        s.is_srgb = srgb;
        s.sampler = ImageSampler::Descriptor(ImageSamplerDescriptor {
            address_mode_u: ImageAddressMode::Repeat,
            address_mode_v: ImageAddressMode::Repeat,
            ..ImageSamplerDescriptor::linear()
        });
    })
}

fn rect(w: f32, h: f32) -> Mesh {
    let mut mesh = Rectangle::new(w, h).mesh().build();
    let _ = mesh.generate_tangents();
    mesh
}

fn block(x: f32, y: f32, z: f32) -> Mesh {
    let mut mesh = Cuboid::new(x, y, z).mesh().build();
    let _ = mesh.generate_tangents();
    mesh
}

fn rgb(c: [f32; 3]) -> Color {
    Color::srgb(c[0], c[1], c[2])
}

// ============================================================================
// Camera: wake-at-frontier dolly, daily recap, ease-out hover
// ============================================================================

/// Advance the camera forward along the chained spine. On the first wake of the day a
/// fast-travel **recap** sweeps the last few legs, then settles into the slow **drift**
/// toward the frontier, **easing out to a hover** at the leading edge (never loops or
/// reverses). Reduced motion freezes the dolly to a near-static parallax hover. Window-
/// drag lean (`react.yaw/pitch`, tweened by `WindowReactPlugin`) nudges the framing.
/// `NIMBUS_FLUX_JOURNEY_CAM="x,y,z,lx,ly,lz"` parks the camera for deterministic captures.
fn drive_camera(
    time: Res<Time>,
    react: Res<WindowReact>,
    journey: Res<Journey>,
    mut pb: ResMut<JourneyPlayback>,
    mut q: Query<&mut Transform, With<JourneyCam>>,
) {
    if let Some(v) = pb.park {
        for mut tr in &mut q {
            tr.translation = Vec3::new(v[0], v[1], v[2]);
            tr.look_at(Vec3::new(v[3], v[4], v[5]), Vec3::Y);
        }
        return;
    }
    if journey.spine.len() < 2 {
        return;
    }

    let dt = time.delta_secs();
    let t = time.elapsed_secs();

    match pb.phase {
        Phase::Recap => {
            pb.recap_t += dt;
            let f = ease_out_cubic(pb.recap_t / pb.recap_dur);
            pb.progress = pb.recap_from + (pb.recap_to - pb.recap_from) * f;
            if pb.recap_t >= pb.recap_dur {
                pb.phase = Phase::Drift;
                pb.progress = pb.recap_to;
            }
        }
        Phase::Drift => {
            if !pb.reduced_motion {
                // ease-out as we approach the frontier hover, then hold (no loop)
                let dist_to_hover = (pb.hover_target - pb.progress).max(0.0);
                let zone = journey.typical_leg * 0.6;
                let v = pb.speed * smoothstep(dist_to_hover / zone);
                pb.progress = (pb.progress + v * dt).min(pb.hover_target);
            }
        }
    }

    let (pos, _) = sample_spine(&journey.spine, pb.progress);
    let (ahead, _) = sample_spine(&journey.spine, (pb.progress + 3.0).min(journey.total));
    let (sway, bob) = if pb.reduced_motion {
        (0.0, 0.0)
    } else {
        ((t * 0.13).sin() * 0.35, (t * 0.26).sin() * 0.12)
    };
    let look_x = ahead.x + (react.yaw * 5.0).clamp(-7.0, 7.0);
    let look_y = (journey.eye - react.pitch * 3.0).clamp(-1.0, 4.5);
    for mut tr in &mut q {
        tr.translation = Vec3::new(pos.x + sway, journey.eye + bob, pos.z);
        tr.look_at(Vec3::new(look_x, look_y, ahead.z), Vec3::Y);
    }
}

/// Flame flicker: layered sines per torch, decorrelated by `phase`.
fn flicker_torches(time: Res<Time>, mut q: Query<(&mut PointLight, &Torch)>) {
    let t = time.elapsed_secs();
    for (mut light, torch) in &mut q {
        let p = torch.phase;
        let f = 0.62
            + 0.20 * (t * 11.0 + p).sin()
            + 0.12 * (t * 23.0 + p * 1.7).sin()
            + 0.06 * (t * 41.0 + p * 2.3).sin();
        light.intensity = torch.base * f.clamp(0.35, 1.25);
    }
}

/// Arc-length sample of the spine polyline → (position, forward tangent).
fn sample_spine(points: &[Vec3], d: f32) -> (Vec3, Vec3) {
    if points.is_empty() {
        return (Vec3::ZERO, Vec3::NEG_Z);
    }
    let mut remaining = d.max(0.0);
    for w in points.windows(2) {
        let seg = w[1] - w[0];
        let len = seg.length();
        if remaining <= len || len < 1e-5 {
            let f = if len > 1e-5 { (remaining / len).clamp(0.0, 1.0) } else { 0.0 };
            return (w[0].lerp(w[1], f), seg.normalize_or_zero());
        }
        remaining -= len;
    }
    let n = points.len();
    let tan = if n >= 2 { (points[n - 1] - points[n - 2]).normalize_or_zero() } else { Vec3::NEG_Z };
    (*points.last().unwrap(), tan)
}

fn smoothstep(x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    x * x * (3.0 - 2.0 * x)
}

fn ease_out_cubic(x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    1.0 - (1.0 - x).powi(3)
}

// ============================================================================
// RT: register meshes into Solari's acceleration structure as they load
// ============================================================================

fn register_raytracing_meshes(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    q: Query<(Entity, &Mesh3d), Without<RaytracingMesh3d>>,
) {
    for (entity, Mesh3d(handle)) in &q {
        let Some(mesh) = meshes.get_mut(handle) else {
            continue;
        };
        let vc = mesh.count_vertices();
        if !mesh.contains_attribute(Mesh::ATTRIBUTE_UV_0) {
            mesh.insert_attribute(Mesh::ATTRIBUTE_UV_0, vec![[0.0_f32, 0.0]; vc]);
        }
        if !mesh.contains_attribute(Mesh::ATTRIBUTE_TANGENT) {
            mesh.insert_attribute(Mesh::ATTRIBUTE_TANGENT, vec![[0.0_f32, 0.0, 0.0, 0.0]; vc]);
        }
        commands.entity(entity).insert(RaytracingMesh3d(handle.clone()));
    }
}

// ============================================================================
// State persistence ($XDG_STATE_HOME/nimbus-flux/state.json)
// ============================================================================

/// Periodically persist `{ last_recap, progress }` so a same-day relaunch resumes the
/// drift and skips the recap, while the first launch of a new day replays it. Off for
/// capture / parked / leg-override runs so dev captures never clobber real state.
fn persist_state(time: Res<Time>, pb: Res<JourneyPlayback>, mut acc: Local<f32>) {
    if !pb.persist {
        return;
    }
    *acc += time.delta_secs();
    if *acc < 5.0 {
        return;
    }
    *acc = 0.0;
    write_state(&pb.today, pb.progress);
}

fn state_path() -> PathBuf {
    let base = std::env::var("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state")
        });
    base.join("nimbus-flux")
}

fn read_state() -> (Option<String>, f32) {
    let p = state_path().join("state.json");
    if let Ok(s) = std::fs::read_to_string(&p) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&s) {
            let lr = v.get("last_recap").and_then(|x| x.as_str()).map(str::to_string);
            let pr = v.get("progress").and_then(|x| x.as_f64()).unwrap_or(0.0) as f32;
            return (lr, pr);
        }
    }
    (None, 0.0)
}

fn write_state(last_recap: &str, progress: f32) {
    let dir = state_path();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let body = format!("{{\"last_recap\":\"{last_recap}\",\"progress\":{progress:.3}}}");
    let _ = std::fs::write(dir.join("state.json"), body);
}

/// Today's date "YYYY-MM-DD". Prefer `NIMBUS_FLUX_TODAY` (the launcher passes the *local*
/// `date +%F`); otherwise derive a UTC date from the system clock. "First wake of the
/// day" keys off this, not process start, so a mid-day reboot doesn't replay the recap.
fn today_string() -> String {
    if let Ok(d) = std::env::var("NIMBUS_FLUX_TODAY") {
        if !d.trim().is_empty() {
            return d;
        }
    }
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, m, d) = civil_from_days((secs / 86400) as i64);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Days-since-epoch → (year, month, day), UTC. Howard Hinnant's `civil_from_days`
/// (avoids pulling in chrono just for a date stamp).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (y + if m <= 2 { 1 } else { 0 }, m, d)
}

// ============================================================================
// Leg loading + small env helpers
// ============================================================================

/// Resolve the journey manifest directory: explicit `NIMBUS_FLUX_JOURNEY_DIR`, else
/// `$BEVY_ASSET_ROOT/journey`, else `./journey`.
fn journey_dir() -> PathBuf {
    if let Ok(d) = std::env::var("NIMBUS_FLUX_JOURNEY_DIR") {
        return PathBuf::from(d);
    }
    if let Ok(root) = std::env::var("BEVY_ASSET_ROOT") {
        return PathBuf::from(root).join("journey");
    }
    PathBuf::from("journey")
}

/// Read `leg-*.json` in lexical order; parse each, skipping (+ logging) any that fail
/// so one bad leg never crashes the wallpaper.
fn load_legs(dir: &PathBuf) -> Vec<LegManifest> {
    let mut paths: Vec<PathBuf> = match std::fs::read_dir(dir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.starts_with("leg-") && n.ends_with(".json"))
                    .unwrap_or(false)
            })
            .collect(),
        Err(e) => {
            warn!("journey: cannot read {:?}: {}", dir, e);
            return Vec::new();
        }
    };
    paths.sort();

    let mut legs = Vec::new();
    for p in paths {
        match std::fs::read_to_string(&p)
            .map_err(|e| e.to_string())
            .and_then(|s| serde_json::from_str::<LegManifest>(&s).map_err(|e| e.to_string()))
        {
            Ok(leg) => legs.push(leg),
            Err(e) => warn!("journey: skipping invalid leg {:?}: {}", p, e),
        }
    }
    legs
}

fn env_f32(k: &str) -> Option<f32> {
    std::env::var(k).ok().and_then(|s| s.trim().parse().ok())
}

fn env_usize(k: &str) -> Option<usize> {
    std::env::var(k).ok().and_then(|s| s.trim().parse().ok())
}

fn env_truthy(k: &str) -> bool {
    matches!(std::env::var(k).ok().as_deref(), Some("1") | Some("true") | Some("on") | Some("yes"))
}

/// Parse a comma-separated list of exactly 6 floats (for `NIMBUS_FLUX_JOURNEY_CAM`).
fn parse6(spec: String) -> Option<[f32; 6]> {
    let v: Vec<f32> = spec.split(',').filter_map(|s| s.trim().parse().ok()).collect();
    (v.len() == 6).then(|| [v[0], v[1], v[2], v[3], v[4], v[5]])
}

// ============================================================================
// Headless tests — the journey LOGIC (portal chaining, windowing, spine, dates).
// GPU-free, so step-3 correctness is verifiable even when NVIDIA+Wayland windowed
// captures are flaking on the swapchain (cf. window_react.rs's tests).
// ============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    fn portal(at: [f32; 3], forward: [f32; 3]) -> Portal {
        Portal { at, forward, up: [0.0, 1.0, 0.0], aperture: [6.0, 5.2] }
    }

    /// Problem A: chaining must make each leg's entry coincide with the previous leg's
    /// exit — position AND travel direction — even when a leg turns. This is the
    /// invariant behind the "invisible seam".
    #[test]
    fn portal_chain_aligns_seams_including_a_turn() {
        // (entry, exit) per leg, each in its own local frame. Leg 1 exits turned in yaw
        // so the journey bends — the join must still be continuous.
        let legs = [
            (portal([0.0, 2.6, 0.0], [0.0, 0.0, -1.0]), portal([0.0, 2.6, -48.0], [0.0, 0.0, -1.0])),
            (portal([0.0, 2.6, 0.0], [0.0, 0.0, -1.0]), portal([2.0, 2.6, -40.0], [0.35, 0.0, -1.0])),
            (portal([0.0, 2.6, 0.0], [0.0, 0.0, -1.0]), portal([0.0, 2.6, -30.0], [0.0, 0.0, -1.0])),
        ];
        let mut world = Affine3A::IDENTITY;
        let mut prev: Option<(Affine3A, Portal)> = None;
        for (entry, exit) in legs.iter() {
            if let Some((pw, pe)) = &prev {
                world = *pw * portal_affine(pe) * portal_affine(entry).inverse();
                let exit_frame = *pw * portal_affine(pe);
                let entry_frame = world * portal_affine(entry);
                let pa = exit_frame.transform_point3(Vec3::ZERO);
                let pb = entry_frame.transform_point3(Vec3::ZERO);
                assert!(pa.distance(pb) < 1e-4, "seam position misaligned: {pa:?} vs {pb:?}");
                let fa = exit_frame.transform_vector3(Vec3::NEG_Z);
                let fb = entry_frame.transform_vector3(Vec3::NEG_Z);
                assert!(fa.angle_between(fb) < 1e-3, "seam travel-dir misaligned");
            }
            prev = Some((world, exit.clone()));
        }
    }

    /// Streaming stays bounded: at the frontier of a long journey only a handful of legs
    /// are live, and the deep past is dropped — no matter how many legs accumulate.
    #[test]
    fn window_is_bounded_at_the_frontier() {
        let spans: Vec<(f32, f32)> =
            (0..50).map(|i| (i as f32 * 48.0, (i as f32 + 1.0) * 48.0)).collect();
        let typical = 48.0;
        let progress = 49.0 * 48.0 + 1.0; // just inside the newest (50th) leg
        let idx = window_indices(&spans, progress, typical * 1.2, typical * 1.2);
        assert!(idx.len() <= 3, "window must stay bounded regardless of length, got {idx:?}");
        assert!(idx.contains(&49) && idx.contains(&48), "frontier + predecessor must be live");
        assert!(!idx.contains(&0), "the deep past must be despawned");
    }

    #[test]
    fn sample_spine_walks_arc_length() {
        let pts = vec![Vec3::ZERO, Vec3::new(0.0, 0.0, -10.0), Vec3::new(0.0, 0.0, -25.0)];
        assert!(sample_spine(&pts, 0.0).0.distance(Vec3::ZERO) < 1e-4);
        let (p1, t1) = sample_spine(&pts, 5.0);
        assert!((p1.z + 5.0).abs() < 1e-4, "5 m in → z=-5, got {}", p1.z);
        assert!((t1 - Vec3::NEG_Z).length() < 1e-4, "tangent points forward (−Z)");
        let (p2, _) = sample_spine(&pts, 17.5);
        assert!((p2.z + 17.5).abs() < 1e-4, "into 2nd segment → z=-17.5, got {}", p2.z);
        let (p3, _) = sample_spine(&pts, 9999.0);
        assert!((p3.z + 25.0).abs() < 1e-4, "past the end clamps to the last point");
    }

    #[test]
    fn civil_from_days_known_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
        assert_eq!(civil_from_days(10957), (2000, 1, 1));
    }

    /// State round-trip: what `persist_state` writes is what the next launch reads back,
    /// so a same-day relaunch resumes progress + skips the recap (recap keys off the date).
    #[test]
    fn state_round_trips_through_disk() {
        let dir = std::env::temp_dir().join(format!("nimbus-flux-state-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("XDG_STATE_HOME", &dir);

        write_state("2026-06-14", 137.5);
        let (last, progress) = read_state();
        assert_eq!(last.as_deref(), Some("2026-06-14"));
        assert!((progress - 137.5).abs() < 1e-2, "progress survives the round-trip, got {progress}");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn easings_hit_endpoints_and_clamp() {
        assert!(smoothstep(0.0).abs() < 1e-6 && (smoothstep(1.0) - 1.0).abs() < 1e-6);
        assert_eq!(smoothstep(-5.0), 0.0);
        assert_eq!(smoothstep(5.0), 1.0);
        assert!(ease_out_cubic(0.0).abs() < 1e-6 && (ease_out_cubic(1.0) - 1.0).abs() < 1e-6);
        assert!(ease_out_cubic(0.5) > 0.5, "ease-out is fast first: f(0.5) > 0.5");
    }
}
