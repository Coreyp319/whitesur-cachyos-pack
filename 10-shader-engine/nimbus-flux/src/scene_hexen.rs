//! Layer-10 "hexen" scene — a 2.5D gothic-dungeon flythrough showpiece.
//!
//! Activated with `NIMBUS_FLUX_SCENE=hexen` (the default when `NIMBUS_FLUX_WALLPAPER=1`).
//! A torch-lit stone corridor recreating the mood of Raven's Hexen/Heretic: real 3-D
//! masonry built procedurally and clad in Poly Haven CC0 PBR stone, gothic props
//! (a marble bust, barrels, candle holders, a brass lantern) dressing the hall, warm
//! flickering torch lights against a cool moonlit ambient, and an HDR + bloom camera
//! gliding slowly down the nave through soft exponential fog toward the bust.
//!
//! Modern-fidelity gothic homage (full-res PBR, smooth bloom, soft fog) rather than a
//! deliberately pixelated retro filter — the geometry/lighting carry the Hexen feel.
//!
//! Assets are fetched by `fetch-hexen-assets.sh` into `assets/hexen/`; the scene loads
//! them by the paths that script writes.

use std::f32::consts::FRAC_PI_2;

use bevy::camera::{CameraMainTextureUsages, Exposure};
use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::image::{ImageAddressMode, ImageLoaderSettings, ImageSampler, ImageSamplerDescriptor};
use bevy::light::{FogVolume, VolumetricFog, VolumetricLight};
use bevy::math::Affine2;
use bevy::pbr::{DistanceFog, FogFalloff, ParallaxMappingMethod, ScreenSpaceAmbientOcclusion};
use bevy::post_process::bloom::Bloom;
use bevy::prelude::*;
use bevy::render::render_resource::TextureUsages;
use bevy::render::view::Hdr;
use bevy::solari::prelude::{RaytracingMesh3d, SolariLighting};
#[cfg(feature = "dlss")]
use bevy::anti_alias::dlss::{
    Dlss, DlssPerfQualityMode, DlssRayReconstructionFeature, DlssRayReconstructionSupported,
};
use bevy_live_wallpaper::LiveWallpaperCamera;

use crate::window_react::{WindowReact, WindowReactPlugin};

// Corridor dimensions (metres). The hall runs along Z; the camera dollies down it.
const HALL_W: f32 = 6.0;
const HALL_H: f32 = 5.2;
const HALL_LEN: f32 = 60.0;
const HALF_LEN: f32 = HALL_LEN * 0.5;
const COL_SPACING: f32 = 7.5;
const BUST_Z: f32 = -HALF_LEN + 4.0; // focal point at the far end

pub struct HexenPlugin {
    /// Ray-traced lighting via bevy_solari (set by NIMBUS_FLUX_RT=1).
    pub rt: bool,
}

#[derive(Resource, Clone, Copy)]
struct RtMode(bool);

impl Plugin for HexenPlugin {
    fn build(&self, app: &mut App) {
        // Warm near-black void so the fogged far end melts into darkness.
        app.insert_resource(ClearColor(Color::srgb(0.018, 0.013, 0.010)))
            .insert_resource(RtMode(self.rt))
            .add_plugins(WindowReactPlugin)
            .add_systems(Startup, setup)
            .add_systems(Update, (flicker_torches, glide_camera));
        // RT mode: register every mesh (procedural + glTF, as they load) into Solari's
        // acceleration structure.
        if self.rt {
            app.add_systems(Update, register_raytracing_meshes);
            // DLSS Ray Reconstruction denoises Solari's output when built
            // --features dlss and the GPU supports it.
            #[cfg(feature = "dlss")]
            app.add_systems(Update, add_dlss_denoiser);
        }
    }
}

#[derive(Component)]
struct DungeonCam;

/// A torch light; `base` is its calm intensity, `phase` decorrelates the flicker.
#[derive(Component)]
struct Torch {
    base: f32,
    phase: f32,
}

/// Externalized refinement knobs, read from the JSON file named by
/// `NIMBUS_FLUX_HEXEN_TUNING` at `setup()`. This is the small sibling of the
/// dreaming-phase manifest: a tuning model (or a human) edits *validated data*, never
/// code — so the see-and-adjust loop never compiles, never breaks the build, and never
/// collides with the RT/DLSS source edits. A missing / unreadable / unparseable file —
/// or any missing field — falls back to the previously-hardcoded default, and EVERY
/// field is clamped to its safe range on load, so the data can't drive the scene out of
/// bounds. Only RASTER/shared values live here; the `if rt {…}` lighting is the DLSS
/// session's and is never externalized.
#[derive(Clone, Copy)]
struct HexenTuning {
    /// hero brick wall `perceptual_roughness` — lower = wetter gloss that reveals relief.
    wall_roughness: f32,
    /// hero brick wall parallax `depth` — >0.06 smears on the stretched single-tile UV.
    wall_depth: f32,
    /// cool moonlight key `illuminance` (raster path only) — warm/cool contrast = depth.
    moonlight: f32,
}

impl Default for HexenTuning {
    /// The values that were hardcoded before externalization (the last-good baseline).
    fn default() -> Self {
        Self { wall_roughness: 0.7, wall_depth: 0.045, moonlight: 850.0 }
    }
}

impl HexenTuning {
    fn load() -> Self {
        let mut t = Self::default();
        let Ok(path) = std::env::var("NIMBUS_FLUX_HEXEN_TUNING") else {
            return t; // unset → today's hardcoded defaults, no file needed
        };
        let parsed = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok());
        let Some(v) = parsed else {
            warn!("hexen tuning '{path}' missing/unreadable/invalid — using defaults");
            return t;
        };
        let num = |k: &str, d: f32| v.get(k).and_then(|x| x.as_f64()).map(|x| x as f32).unwrap_or(d);
        // Clamp EVERY field to its safe range — the hard guardrail (the loop's JSON is
        // also range-checked, but the renderer never trusts that). Ranges mirror
        // SCENE-COMPOSITION.md / the refinement handoff's knob table.
        t.wall_roughness = num("wall_roughness", t.wall_roughness).clamp(0.5, 0.95);
        t.wall_depth = num("wall_depth", t.wall_depth).clamp(0.0, 0.06);
        t.moonlight = num("moonlight", t.moonlight).clamp(400.0, 1400.0);
        info!(
            "hexen tuning loaded from '{path}': wall_roughness={} wall_depth={} moonlight={}",
            t.wall_roughness, t.wall_depth, t.moonlight
        );
        t
    }
}

fn setup(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<StandardMaterial>>,
    assets: Res<AssetServer>,
    rt_mode: Res<RtMode>,
) {
    let rt = rt_mode.0;
    // Refinement knobs from NIMBUS_FLUX_HEXEN_TUNING (data, not code); defaults match
    // the previously-hardcoded values, so an unset env renders identically to before.
    let tuning = HexenTuning::load();

    // ---- camera: HDR + filmic tonemap + bloom. The raster path adds SSAO + ray-marched
    // volumetric fog; the ray-traced path (Solari) replaces them with traced GI + shadows
    // and leans on a much lower ambient because the bounce light is computed.
    // The full atmospheric scene (normal-mapped stone, shadows, volumetric god-rays) is
    // kept in BOTH paths; ray-tracing layers Solari's bounce GI + soft shadows on top.
    let mut cam = commands.spawn((
        Camera3d::default(),
        Hdr,
        Tonemapping::TonyMcMapface,
        Bloom::NATURAL,
        Msaa::Off, // required by both SSAO and Solari
        AmbientLight {
            color: Color::srgb(0.42, 0.52, 0.85), // cold moonlight bounce
            brightness: 42.0, // dimmer fill → torches model real form, shadows stay deep
            ..default()
        },
        // ray-marched volumetric haze + torch god-rays — atmosphere in both paths.
        VolumetricFog {
            ambient_intensity: 0.12,
            jitter: 0.5,
            ..default()
        },
        // cheap distance haze for the far fade.
        DistanceFog {
            color: Color::srgb(0.020, 0.016, 0.013),
            directional_light_color: Color::srgb(0.9, 0.55, 0.25),
            directional_light_exponent: 18.0,
            falloff: FogFalloff::Exponential { density: 0.007 }, // eased: don't curtain detail
        },
        Transform::from_xyz(0.0, 1.7, HALF_LEN - 5.0)
            .looking_at(Vec3::new(0.0, 1.6, BUST_Z), Vec3::Y),
        DungeonCam,
        LiveWallpaperCamera, // inert unless LiveWallpaperPlugin is active (wallpaper mode)
    ));
    if rt {
        // Solari adds ray-traced indirect bounce + soft shadows; needs a storage-bindable
        // main texture. (SSAO is redundant with traced occlusion, so it's raster-only.)
        cam.insert((
            SolariLighting::default(),
            CameraMainTextureUsages::default().with(TextureUsages::STORAGE_BINDING),
            // Solari outputs physical radiance; the default daylight exposure
            // (ev100 9.7) under-exposes this torch-lit interior. Brighten it.
            Exposure { ev100: 6.5 },
        ));
    } else if std::env::var("NIMBUS_FLUX_WALLPAPER").is_err() {
        // SSAO builds a depth-mip pyramid sized to the view; under the
        // bevy_live_wallpaper layer-shell surface that size isn't ready when SSAO
        // prepares its textures, so it asks for 5 mips on a 1x1 texture and wgpu panics
        // ("mip level count 5 is invalid, maximum allowed is 1"). Skip SSAO as a wallpaper.
        cam.insert(ScreenSpaceAmbientOcclusion::default());
    }

    // bounded volume the ray-marcher fills with warm haze — sized to the corridor.
    commands.spawn((
        FogVolume {
            fog_color: Color::srgb(0.62, 0.40, 0.22),
            density_factor: 0.028, // thin: scatters torch shafts, doesn't curtain the hall
            scattering: 0.6,
            ..default()
        },
        Transform::from_xyz(0.0, HALL_H / 2.0, 0.0)
            .with_scale(Vec3::new(HALL_W, HALL_H, HALL_LEN)),
    ));

    // cold "moonlight" raking down the hall — shadow-casting + volumetric so it throws
    // broad dusty shafts and a complementary cool key against the warm torches.
    commands.spawn((
        DirectionalLight {
            // Solari lights surfaces from real lights only (it ignores flat AmbientLight),
            // so the moonlight key carries the global fill in RT; raster leans on ambient.
            illuminance: if rt { 7000.0 } else { tuning.moonlight }, // cool key vs. warm torches —
            // the complementary contrast is what reads as depth, not a single orange wash
            color: Color::srgb(0.55, 0.65, 0.95),
            shadows_enabled: true,
            ..default()
        },
        VolumetricLight,
        Transform::from_xyz(2.0, 12.0, HALF_LEN).looking_at(Vec3::new(0.0, 0.0, -HALF_LEN), Vec3::Y),
    ));

    // ---- stone materials (Poly Haven CC0). `arm` packs AO=R, Rough=G, Metal=B, which
    // feeds bevy's metallic-roughness + occlusion directly; stone's ~0 metal keeps it
    // dielectric even with metallic=1.0 scaling the map. Each surface gets its own
    // material so its UV tiling (uv_transform) is independent.
    // floor is glossier (0.5) so torch flames glint off it like damp flagstones.
    // Lower roughness than bare stone: damp dungeon masonry catches grazing torch
    // speculars, and a specular highlight is what actually *reveals* the normal + parallax
    // relief (a fully matte surface hides both). Floor is wettest (flagstone glints), the
    // brick walls — the hero surface, viewed near face-on — carry the most parallax.
    // Parallax depth is RELATIVE TO ONE TEXTURE TILE's world size, so it must stay modest
    // on the big planes (a tile is metres wide); on `trim` — columns/ribs/pedestals clad in
    // a single stretched tile — any parallax smears badly, so it's disabled there (0.0) and
    // those surfaces rely on the normal map alone.
    let floor_mat = stone_material(&mut materials, &assets, "medieval_blocks_02", Vec2::new(HALL_W / 2.0, HALL_LEN / 2.0), 0.45, 0.03);
    let ceil_mat = stone_material(&mut materials, &assets, "castle_wall_slates", Vec2::new(HALL_W / 3.0, HALL_LEN / 3.0), 0.85, 0.025);
    let wall_mat = stone_material(&mut materials, &assets, "castle_brick_07", Vec2::new(HALL_LEN / 1.7, HALL_H / 1.7), tuning.wall_roughness, tuning.wall_depth);
    let trim_mat = stone_material(&mut materials, &assets, "castle_wall_slates", Vec2::new(1.0, 2.0), 0.8, 0.0);

    // ---- floor & ceiling (Rectangle: local X→U, local Y→V, so tiling stays square).
    commands.spawn((
        Mesh3d(meshes.add(rect(HALL_W, HALL_LEN))),
        MeshMaterial3d(floor_mat),
        Transform::from_xyz(0.0, 0.0, 0.0).with_rotation(Quat::from_rotation_x(-FRAC_PI_2)),
    ));
    commands.spawn((
        Mesh3d(meshes.add(rect(HALL_W, HALL_LEN))),
        MeshMaterial3d(ceil_mat),
        Transform::from_xyz(0.0, HALL_H, 0.0).with_rotation(Quat::from_rotation_x(FRAC_PI_2)),
    ));

    // ---- side walls (Rectangle length→U, height→V; faces rotated to point inward).
    let wall_mesh = meshes.add(rect(HALL_LEN, HALL_H));
    commands.spawn((
        Mesh3d(wall_mesh.clone()),
        MeshMaterial3d(wall_mat.clone()),
        Transform::from_xyz(-HALL_W / 2.0, HALL_H / 2.0, 0.0)
            .with_rotation(Quat::from_rotation_y(FRAC_PI_2)),
    ));
    commands.spawn((
        Mesh3d(wall_mesh),
        MeshMaterial3d(wall_mat),
        Transform::from_xyz(HALL_W / 2.0, HALL_H / 2.0, 0.0)
            .with_rotation(Quat::from_rotation_y(-FRAC_PI_2)),
    ));

    // ---- columns + transverse ribs give the arcade rhythm, plus a torch per bay
    // (alternating sides so the light staggers down the hall).
    let col_mesh = meshes.add(block(0.7, HALL_H, 0.7));
    let rib_mesh = meshes.add(block(HALL_W + 0.5, 0.6, 0.7));
    let mut z = -HALF_LEN + COL_SPACING;
    let mut bay = 0;
    while z < HALF_LEN - 1.0 {
        for side in [-1.0_f32, 1.0] {
            commands.spawn((
                Mesh3d(col_mesh.clone()),
                MeshMaterial3d(trim_mat.clone()),
                Transform::from_xyz(side * (HALL_W / 2.0 - 0.3), HALL_H / 2.0, z),
            ));
        }
        commands.spawn((
            Mesh3d(rib_mesh.clone()),
            MeshMaterial3d(trim_mat.clone()),
            Transform::from_xyz(0.0, HALL_H - 0.45, z),
        ));

        // torch on the bay's lit side
        let side = if bay % 2 == 0 { -1.0 } else { 1.0 };
        spawn_torch(
            &mut commands,
            &mut meshes,
            &mut materials,
            Vec3::new(side * (HALL_W / 2.0 - 0.55), 3.1, z),
            bay,
            rt,
        );

        z += COL_SPACING;
        bay += 1;
    }

    // ---- props (Poly Haven CC0 glTF). Loaded by the paths fetch-hexen-assets.sh writes.
    // marble bust on a pedestal, framed at the end of the nave
    commands.spawn((
        Mesh3d(meshes.add(block(1.1, 1.3, 1.1))),
        MeshMaterial3d(trim_mat.clone()),
        Transform::from_xyz(0.0, 0.65, BUST_Z),
    ));
    commands.spawn((
        SceneRoot(assets.load(
            GltfAssetLabel::Scene(0).from_asset("hexen/models/marble_bust_01/marble_bust_01_2k.gltf"),
        )),
        // Face up the hall toward the approaching camera (the dolly looks down −Z, so the
        // bust's +Z native front needs no Y-flip — the previous PI turned its back to us).
        Transform::from_xyz(0.0, 1.3, BUST_Z)
            .with_scale(Vec3::splat(1.9))
            .with_rotation(Quat::from_rotation_y(0.0)),
    ));
    // a warm key on the bust so it reads through the fog (shadowed + volumetric halo)
    commands.spawn((
        PointLight {
            color: Color::srgb(1.0, 0.72, 0.42),
            intensity: if rt { 360_000.0 } else { 120_000.0 },
            range: 14.0,
            shadows_enabled: true,
            ..default()
        },
        VolumetricLight,
        Transform::from_xyz(0.0, 3.2, BUST_Z + 3.0),
    ));

    // barrels down the hall
    for (x, zb, ry) in [
        (HALL_W / 2.0 - 0.75, 11.0, 0.3),
        (-(HALL_W / 2.0 - 0.85), -3.0, 1.1),
        (-(HALL_W / 2.0 - 0.7), 18.5, 2.2),
    ] {
        commands.spawn((
            SceneRoot(assets.load(
                GltfAssetLabel::Scene(0).from_asset("hexen/models/Barrel_01/Barrel_01_2k.gltf"),
            )),
            Transform::from_xyz(x, 0.0, zb).with_rotation(Quat::from_rotation_y(ry)),
        ));
    }

    // candle holder on the pedestal in front of the bust, with its own little glow
    commands.spawn((
        SceneRoot(assets.load(GltfAssetLabel::Scene(0).from_asset(
            "hexen/models/brass_candleholders/brass_candleholders_2k.gltf",
        ))),
        Transform::from_xyz(0.0, 1.3, BUST_Z + 0.55).with_scale(Vec3::splat(1.3)),
    ));
    commands.spawn((
        PointLight {
            color: Color::srgb(1.0, 0.6, 0.28),
            intensity: if rt { 90_000.0 } else { 26_000.0 },
            range: 6.0,
            shadows_enabled: false,
            ..default()
        },
        Transform::from_xyz(0.0, 1.85, BUST_Z + 0.55),
    ));

    // brass lantern resting by a column near the entrance, lit from within
    commands.spawn((
        SceneRoot(assets.load(
            GltfAssetLabel::Scene(0).from_asset("hexen/models/Lantern_01/Lantern_01_2k.gltf"),
        )),
        Transform::from_xyz(HALL_W / 2.0 - 0.8, 0.0, 3.0),
    ));
    commands.spawn((
        PointLight {
            color: Color::srgb(1.0, 0.66, 0.32),
            intensity: if rt { 100_000.0 } else { 30_000.0 },
            range: 7.0,
            shadows_enabled: false,
            ..default()
        },
        Transform::from_xyz(HALL_W / 2.0 - 0.8, 0.6, 3.0),
    ));

    // ---- treasure chest: the focal "reward" at the very end of the nave, set in front of
    // the bust pedestal so it reads down the whole hall (the bust key light catches it, and
    // it's scaled up so it still registers through the distance haze). Slightly off-centre
    // and angled toward the viewer.
    commands.spawn((
        SceneRoot(assets.load(
            GltfAssetLabel::Scene(0).from_asset("hexen/models/treasure_chest/treasure_chest_2k.gltf"),
        )),
        Transform::from_xyz(-0.85, 0.0, BUST_Z + 2.3)
            .with_scale(Vec3::splat(1.5))
            .with_rotation(Quat::from_rotation_y(0.35)),
    ));

    // ---- near/mid-hall dressing so the foreground isn't bare (CC0 Poly Haven glTF):
    // crates, a wine barrel + bucket, broken-masonry rubble and a shield leaning on the
    // wall, distributed down the hall. They hug the walls (|x| ≳ 2) so they never block the
    // central dolly, and scatter in z from the entrance (z≈19) toward the bust.
    for (model, x, y, z, scale, rot) in [
        ("wooden_crate_01", -2.0, 0.0, 19.0, 1.0, Quat::from_rotation_y(0.4)),
        ("wooden_crate_01", 2.25, 0.0, 0.0, 1.0, Quat::from_rotation_y(2.3)),
        ("wine_barrel_01", -2.4, 0.0, 7.0, 1.0, Quat::from_rotation_y(0.8)),
        ("wooden_bucket_01", -2.05, 0.0, 9.3, 1.0, Quat::from_rotation_y(1.5)),
        ("rock_07", -1.5, 0.0, 11.5, 1.3, Quat::from_rotation_y(1.1)),
        ("rock_07", 1.6, 0.0, -12.0, 1.7, Quat::from_rotation_y(2.7)),
        (
            "kite_shield",
            2.52,
            0.5,
            11.0,
            1.0,
            Quat::from_rotation_y(-FRAC_PI_2) * Quat::from_rotation_x(0.2),
        ),
    ] {
        commands.spawn((
            SceneRoot(assets.load(
                GltfAssetLabel::Scene(0).from_asset(format!("hexen/models/{model}/{model}_2k.gltf")),
            )),
            Transform::from_xyz(x, y, z)
                .with_scale(Vec3::splat(scale))
                .with_rotation(rot),
        ));
    }
}

/// Build a `StandardMaterial` from a Poly Haven stone texture set
/// (`<id>_{diff,nor_gl,arm,disp}`), tiled by `tiles` repeats across the surface UV.
/// `depth` drives parallax-occlusion relief (world depth ≈ `depth` × one tile's world
/// size); 0 disables it. The `_disp_` map is the fetcher-baked depth map (inverted from
/// Poly Haven's height map so the relief protrudes the right way).
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
    // Real grazing-angle relief on the big planes: the normal map only fakes lighting, so
    // masonry still reads flat where torches rake across it. The baked depth map adds
    // parallax displacement; Relief mapping (binary search) avoids the "writhing" Occlusion
    // shows on the slowly-dollying camera. `depth == 0` (small/stretched-UV trim) skips the
    // parallax path entirely — there it only smears.
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
        perceptual_roughness: roughness, // scales the arm.G roughness map (lower = wetter)
        metallic: 1.0,                   // arm.B (~0 for stone) scales it → stays dielectric
        uv_transform: Affine2::from_scale(tiles),
        ..default()
    })
}

/// Load an image with repeat addressing (for tiling) and an explicit sRGB flag —
/// colour maps are sRGB, data maps (normal/arm) must be linear.
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

/// A rectangle mesh with generated tangents (so it can take a normal map).
fn rect(w: f32, h: f32) -> Mesh {
    let mut mesh = Rectangle::new(w, h).mesh().build();
    let _ = mesh.generate_tangents();
    mesh
}

/// A cuboid mesh with generated tangents (columns / ribs / pedestals).
fn block(x: f32, y: f32, z: f32) -> Mesh {
    let mut mesh = Cuboid::new(x, y, z).mesh().build();
    let _ = mesh.generate_tangents();
    mesh
}

/// Spawn a flickering torch: a warm point light plus a small emissive flame the bloom
/// pass turns into a glow.
fn spawn_torch(
    commands: &mut Commands,
    meshes: &mut Assets<Mesh>,
    materials: &mut Assets<StandardMaterial>,
    pos: Vec3,
    bay: i32,
    rt: bool,
) {
    // Brighter in RT: Solari lights the stone only from real lights, so the torches must
    // carry it (and the grazing light is what makes the normal-mapped masonry pop).
    let base = if rt { 900_000.0 } else { 160_000.0 };
    commands.spawn((
        PointLight {
            color: Color::srgb(1.0, 0.55, 0.22),
            intensity: base,
            range: if rt { 34.0 } else { 19.0 },
            shadows_enabled: true, // columns cast long shadows; feeds the volumetric shafts
            ..default()
        },
        VolumetricLight, // its glow ray-marches into a torch shaft through the haze
        Transform::from_translation(pos),
        Torch {
            base,
            phase: bay as f32 * 1.7,
        },
    ));
    // emissive flame (HDR emissive → bloom). Base black so only the emission shows.
    commands.spawn((
        Mesh3d(meshes.add(Sphere::new(0.11).mesh().ico(3).unwrap())),
        MeshMaterial3d(materials.add(StandardMaterial {
            base_color: Color::BLACK,
            emissive: if rt { LinearRgba::rgb(18.0, 7.0, 2.0) } else { LinearRgba::rgb(7.0, 2.6, 0.7) },
            ..default()
        })),
        Transform::from_translation(pos),
    ));
}

/// Organic flame flicker: layered sines per torch, decorrelated by `phase`.
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

/// Slow, looping dolly down the nave toward the bust — eased by a cosine so it pauses
/// gently at each end (no teleport), with a faint sway and bob for life. While a window
/// is dragged, the framing leans in the direction it moved (debounced, spring-smoothed
/// by `WindowReact`) and eases back when the drag stops.
fn glide_camera(
    time: Res<Time>,
    react: Res<WindowReact>,
    mut q: Query<&mut Transform, With<DungeonCam>>,
) {
    // Debug inspection: NIMBUS_FLUX_HEXEN_CAM="x,y,z,lx,ly,lz" parks the camera at a
    // fixed pose (position xyz, looking at lxlylz) instead of dollying, so prop
    // placement/scale/orientation can be checked in a deterministic capture. Inert unset.
    if let Ok(spec) = std::env::var("NIMBUS_FLUX_HEXEN_CAM") {
        let v: Vec<f32> = spec.split(',').filter_map(|s| s.trim().parse().ok()).collect();
        if v.len() == 6 {
            for mut tr in &mut q {
                tr.translation = Vec3::new(v[0], v[1], v[2]);
                tr.look_at(Vec3::new(v[3], v[4], v[5]), Vec3::Y);
            }
            return;
        }
    }

    let t = time.elapsed_secs();
    let near = HALF_LEN - 5.0;
    let far = BUST_Z + 9.0;
    let s = 0.5 - 0.5 * (t * 0.10).cos(); // 0→1→0, eased
    // window-drag lean: +yaw (window moved right) turns the gaze right; +pitch (moved
    // down) tips it down. Clamped so it never swings into the masonry.
    let look_x = (react.yaw * 6.0).clamp(-9.0, 9.0);
    let look_y = (1.6 - react.pitch * 4.0).clamp(-1.5, 4.5);
    for mut tr in &mut q {
        let z = near + (far - near) * s;
        let x = (t * 0.13).sin() * 0.4;
        let y = 1.7 + (t * 0.26).sin() * 0.12;
        tr.translation = Vec3::new(x, y, z);
        tr.look_at(Vec3::new(look_x, look_y, BUST_Z), Vec3::Y);
    }
}

/// (RT mode) Register meshes into Solari's ray-tracing acceleration structure as they
/// become available — procedural meshes immediately, glTF prop meshes once the scene
/// finishes loading. `Without<RaytracingMesh3d>` makes this a one-shot per mesh. Solari
/// also requires UV0 + tangents, so we backfill empties on any mesh missing them.
fn register_raytracing_meshes(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    q: Query<(Entity, &Mesh3d), Without<RaytracingMesh3d>>,
) {
    for (entity, Mesh3d(handle)) in &q {
        let Some(mesh) = meshes.get_mut(handle) else {
            continue; // asset still streaming in — retry next frame
        };
        let vc = mesh.count_vertices();
        if !mesh.contains_attribute(Mesh::ATTRIBUTE_UV_0) {
            mesh.insert_attribute(Mesh::ATTRIBUTE_UV_0, vec![[0.0_f32, 0.0]; vc]);
        }
        if !mesh.contains_attribute(Mesh::ATTRIBUTE_TANGENT) {
            mesh.insert_attribute(Mesh::ATTRIBUTE_TANGENT, vec![[0.0_f32, 0.0, 0.0, 0.0]; vc]);
        }
        commands
            .entity(entity)
            .insert(RaytracingMesh3d(handle.clone()));
    }
}

/// (RT + `dlss` feature) Attach DLSS Ray Reconstruction to the camera once the GPU is
/// known to support it — it denoises Solari's ray-traced output (kills the path-tracing
/// grain) and upscales. `DlssRayReconstructionSupported` is inserted by bevy's dlss
/// plugin only when the driver/GPU can do it, so this no-ops gracefully otherwise.
#[cfg(feature = "dlss")]
fn add_dlss_denoiser(
    mut commands: Commands,
    supported: Option<Res<DlssRayReconstructionSupported>>,
    cam: Query<Entity, (With<DungeonCam>, Without<Dlss<DlssRayReconstructionFeature>>)>,
    mut logged: Local<bool>,
) {
    if supported.is_none() {
        if !*logged {
            warn!("DLSS Ray Reconstruction unsupported on this GPU/driver — RT runs un-denoised");
            *logged = true;
        }
        return;
    }
    for entity in &cam {
        commands.entity(entity).insert(Dlss::<DlssRayReconstructionFeature> {
            // DLAA = native resolution (no upscaling): best denoise quality, and the
            // 4090 has the headroom for it as a wallpaper.
            perf_quality_mode: DlssPerfQualityMode::Dlaa,
            reset: Default::default(),
            _phantom_data: Default::default(),
        });
        if !*logged {
            info!("DLSS Ray Reconstruction attached (DLAA) — denoising the Solari output");
            *logged = true;
        }
    }
}
