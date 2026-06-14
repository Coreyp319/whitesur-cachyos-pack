//! Layer-10 "journey" scene — the dreaming-phase scene composer.
//!
//! Activated with `NIMBUS_FLUX_SCENE=journey`. Renders an ordered, append-only
//! sequence of **leg manifests** (`journey/leg-NNN.json`) as one continuous,
//! seamless corridor the camera travels forever. Each leg is authored in its own
//! local frame; **portal chaining** aligns each leg's entry to the previous leg's
//! exit so the joins are invisible (see `chain` / problem A in the handoff).
//!
//! This is the runtime half of the "dreaming" design: a Layer-6 local model will
//! eventually emit these JSON manifests (referencing only a vetted CC0 catalog),
//! and this already-compiled composer instantiates geometry / props / lights from
//! them at runtime — no compiling AI output. For the MVP (steps 1–2) the legs are
//! **hand-authored** and **zero AI** is involved; the point is to prove the schema
//! is expressive and the seam is seamless.
//!
//! The composer reuses the on-hand `hexen` CC0 asset set (stone textures + glTF
//! props under `assets/hexen/`), so it renders without any extra download. A future
//! catalog (handoff problem H) will generalise the asset paths.
//!
//! Robustness contract: a missing/invalid leg is skipped + logged, never crashes
//! the wallpaper. An empty journey still runs (camera + atmosphere, no geometry).

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
    // carried for the streaming/evolution + provenance work (steps 3+); not yet read.
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
/// moonlight) currently comes from the **first** leg; per-leg blending across the seam
/// is problem J (future). The per-leg `fog_*` here still drive each leg's own
/// `FogVolume`, so legs can vary their local haze.
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
// Plugin + components
// ============================================================================

pub struct JourneyPlugin {
    /// Ray-traced lighting via bevy_solari (NIMBUS_FLUX_RT=1). Opt-in for journey
    /// until the DLSS denoiser is wired (the raw Solari path is grainy); the
    /// wallpaper default for this scene is the cleaner raster path.
    pub rt: bool,
}

#[derive(Resource, Clone, Copy)]
struct RtMode(bool);

/// The chained world-space spine the camera travels: portal centres in order
/// (`entry₀, exit₀ = entry₁, exit₁, …`). Robust to legs that turn.
#[derive(Resource, Default)]
struct JourneySpine {
    points: Vec<Vec3>,
    eye: f32,
    total: f32,
}

#[derive(Component)]
struct JourneyCam;

/// Tags every entity belonging to leg `idx` so a future streaming pass (step 3)
/// can despawn legs the camera has left behind.
#[derive(Component)]
#[allow(dead_code)]
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
            .init_resource::<JourneySpine>()
            .add_plugins(WindowReactPlugin)
            .add_systems(Startup, setup)
            .add_systems(Update, (flicker_torches, glide_camera));
        if self.rt {
            app.add_systems(Update, register_raytracing_meshes);
        }
    }
}

// ============================================================================
// Setup: load legs, chain portals, compose the world
// ============================================================================

fn setup(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    assets: Res<AssetServer>,
    rt_mode: Res<RtMode>,
) {
    let rt = rt_mode.0;
    let dir = journey_dir();
    let legs = load_legs(&dir);
    info!("journey: loaded {} leg(s) from {:?}", legs.len(), dir);
    if legs.is_empty() {
        error!("journey: no valid legs in {:?} — rendering atmosphere only", dir);
    }

    // ---- global atmosphere from the first leg (cross-leg blending = problem J, future)
    let atmos = legs.first().map(|l| l.atmosphere.clone()).unwrap_or_default();
    commands.insert_resource(ClearColor(rgb(atmos.clear)));

    // ---- camera: HDR + filmic tonemap + bloom; raster adds SSAO (windowed only),
    // RT swaps in Solari traced GI + soft shadows. Mirrors the hexen camera so both
    // scenes read the same.
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
        VolumetricFog {
            ambient_intensity: 0.12,
            jitter: 0.5,
            ..default()
        },
        DistanceFog {
            color: rgb(atmos.fog_color),
            directional_light_color: Color::srgb(0.9, 0.55, 0.25),
            directional_light_exponent: 18.0,
            falloff: FogFalloff::Exponential { density: atmos.fog_density },
        },
        // start just behind the first entry, looking down the corridor (−Z)
        Transform::from_xyz(0.0, 1.7, 4.0).looking_at(Vec3::new(0.0, 1.6, -20.0), Vec3::Y),
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

    // ---- global moonlight key (cool complement to the warm torches). Solari lights
    // surfaces only from real lights, so RT leans on this far more than raster does.
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

    // ---- chain the legs and compose. `world` is the running world transform of the
    // leg being placed; for leg N≥1 it is solved so leg N's entry portal coincides
    // (frame-for-frame) with leg N−1's exit portal:
    //     world(N) = world(N−1) · exit_local(N−1) · entry_local(N)⁻¹
    // leg 0 is the anchor: world(0) = identity (authored directly in world space).
    let mut world = Affine3A::IDENTITY;
    let mut spine: Vec<Vec3> = Vec::new();
    let mut prev: Option<(Affine3A, Portal)> = None; // (prev world, prev exit portal)

    for (i, leg) in legs.iter().enumerate() {
        if let Some((prev_world, prev_exit)) = &prev {
            world = *prev_world * portal_affine(prev_exit) * portal_affine(&leg.entry).inverse();

            // seam validation (seed of problem-A guardrails): prev exit centre vs this
            // entry centre in world space — equal by construction; warn if they drift.
            let a = prev_world.transform_point3(Vec3::from(prev_exit.at));
            let b = world.transform_point3(Vec3::from(leg.entry.at));
            let gap = a.distance(b);
            if gap > 1e-3 {
                warn!("journey: seam {} ↔ {} misaligned by {:.4} m", legs[i - 1].id, leg.id, gap);
            }
            if (Vec2::from(prev_exit.aperture) - Vec2::from(leg.entry.aperture)).length() > 0.05 {
                warn!(
                    "journey: seam {} ↔ {} aperture mismatch ({:?} vs {:?})",
                    legs[i - 1].id, leg.id, prev_exit.aperture, leg.entry.aperture
                );
            }
        }

        // spine: leg 0 contributes its entry centre; every leg contributes its exit.
        if i == 0 {
            spine.push(world.transform_point3(Vec3::from(leg.entry.at)));
        }
        spine.push(world.transform_point3(Vec3::from(leg.exit.at)));

        build_leg(&mut commands, &mut meshes, &mut materials, &assets, leg, &world, i, rt);
        info!("journey: placed {} (world Z origin {:.1})", leg.id, world.translation.z);

        prev = Some((world, leg.exit.clone()));
    }

    let total: f32 = spine.windows(2).map(|w| w[0].distance(w[1])).sum();
    commands.insert_resource(JourneySpine { points: spine, eye: 1.7, total });
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

/// Bake a leg-local transform into world space (the leg roots are rigid, no scale,
/// so non-uniform child scale survives the compose).
fn place(world: &Affine3A, local: Transform) -> Transform {
    Transform::from_matrix(Mat4::from(*world) * local.to_matrix())
}

// ============================================================================
// Leg → entities
// ============================================================================

fn build_leg(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    assets: &AssetServer,
    leg: &LegManifest,
    world: &Affine3A,
    idx: usize,
    rt: bool,
) {
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
    for p in &leg.props {
        let local = Transform::from_xyz(p.pos[0], p.pos[1], p.pos[2])
            .with_scale(Vec3::splat(p.scale))
            .with_rotation(Quat::from_rotation_y(p.rot_y));
        commands.spawn((
            SceneRoot(assets.load(
                GltfAssetLabel::Scene(0)
                    .from_asset(format!("hexen/models/{0}/{0}_2k.gltf", p.model)),
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

    // per-leg fog volume sized to the corridor → each leg can carry its own haze tint
    let (w, h, len) = span;
    commands.spawn((
        FogVolume {
            fog_color: rgb(leg.atmosphere.fog_color),
            density_factor: leg.atmosphere.fog_volume_density,
            scattering: 0.6,
            ..default()
        },
        place(
            world,
            Transform::from_xyz(0.0, h / 2.0, -len / 2.0).with_scale(Vec3::new(w, h, len)),
        ),
        LegMember(idx),
    ));
}

/// Build a corridor segment in its local frame (entry at the origin, running toward
/// −Z to `exit` at z = −length): floor / ceiling / walls, an entry archway that frames
/// the seam, a column+rib arcade rhythm, and an alternating torch per bay. All baked
/// into `world`. Material/parallax recipe matches `scene_hexen` (kept local so this
/// file never has to edit the concurrently-owned hexen module).
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

    // materials (own copy per surface so UV tiling is independent). Tiling/roughness/
    // parallax-depth mirror the hexen damp-dungeon recipe.
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

    // ---- entry archway at local z≈0: two piers + a lintel. Placed only at the entry
    // of each leg, so at a seam exactly ONE arch (the next leg's) stands at the join —
    // reading as an intentional threshold that hides the per-leg texture reset, never a
    // pair of z-fighting arches.
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

    // ---- column + rib arcade and a torch per bay (alternating sides). Bays start one
    // spacing in from the entry and stop short of the exit.
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
            spawn_torch(
                commands,
                meshes,
                materials,
                world,
                Vec3::new(side * (w / 2.0 - 0.55), 3.1, z),
                c.torch_color,
                bay,
                idx,
                rt,
            );

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
// Camera + animation
// ============================================================================

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

/// Dolly forward along the chained spine, looking down the corridor. For the MVP this
/// is a slow, eased oscillation over the whole (short) journey — endless forward
/// streaming is step 3, after the camera/playback policy (handoff problem D) is decided.
/// Window-drag lean (`react.yaw/pitch`, fully tweened by `WindowReactPlugin`) leans the
/// framing. `NIMBUS_FLUX_JOURNEY_CAM="x,y,z,lx,ly,lz"` parks the camera for deterministic
/// captures (the journey analogue of hexen's debug cam).
fn glide_camera(
    time: Res<Time>,
    react: Res<WindowReact>,
    spine: Res<JourneySpine>,
    mut q: Query<&mut Transform, With<JourneyCam>>,
) {
    if let Ok(spec) = std::env::var("NIMBUS_FLUX_JOURNEY_CAM") {
        let v: Vec<f32> = spec.split(',').filter_map(|s| s.trim().parse().ok()).collect();
        if v.len() == 6 {
            for mut tr in &mut q {
                tr.translation = Vec3::new(v[0], v[1], v[2]);
                tr.look_at(Vec3::new(v[3], v[4], v[5]), Vec3::Y);
            }
            return;
        }
    }

    if spine.points.len() < 2 {
        return;
    }

    let t = time.elapsed_secs();
    let margin = 4.0;
    let span = (spine.total - 2.0 * margin).max(1.0);
    let s = 0.5 - 0.5 * (t * 0.05).cos(); // 0→1→0, slow ease
    let d = margin + s * span;
    let (pos, _) = sample_spine(&spine.points, d);
    let (ahead, _) = sample_spine(&spine.points, (d + 3.0).min(spine.total));

    let sway = (t * 0.13).sin() * 0.35;
    let bob = (t * 0.26).sin() * 0.12;
    let look_x = ahead.x + (react.yaw * 5.0).clamp(-7.0, 7.0);
    let look_y = (spine.eye - react.pitch * 3.0).clamp(-1.0, 4.5);
    for mut tr in &mut q {
        tr.translation = Vec3::new(pos.x + sway, spine.eye + bob, pos.z);
        tr.look_at(Vec3::new(look_x, look_y, ahead.z), Vec3::Y);
    }
}

/// Arc-length sample of the spine polyline → (position, forward tangent).
fn sample_spine(points: &[Vec3], d: f32) -> (Vec3, Vec3) {
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

// ============================================================================
// RT: register meshes into Solari's acceleration structure as they load
// ============================================================================

/// (RT mode) Same as the hexen path: register procedural + glTF meshes into Solari's
/// BVH once available, backfilling UV0/tangents Solari requires.
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
// Leg loading
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
        match std::fs::read_to_string(&p).map_err(|e| e.to_string()).and_then(|s| {
            serde_json::from_str::<LegManifest>(&s).map_err(|e| e.to_string())
        }) {
            Ok(leg) => legs.push(leg),
            Err(e) => warn!("journey: skipping invalid leg {:?}: {}", p, e),
        }
    }
    legs
}
