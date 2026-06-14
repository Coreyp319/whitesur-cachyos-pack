//! Layer-10 hero overlay — the Blender-authored neon "core" (`assets/hero_core.glb`).
//!
//! Rendered in 3D on a camera composited OVER the fluid sim (order 1, no clear),
//! with HDR + bloom so the emissive glTF glows and slowly spins above the fluid.
//! This is the live-mesh sibling of the wallpaper's baked sprite, and exercises
//! the Blender → glTF → bevy/wgpu asset pipeline end to end.

use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::post_process::bloom::Bloom;   // bevy 0.18 moved bloom out of core_pipeline
use bevy::prelude::*;
use bevy::render::view::Hdr;            // hdr is now a component, not a Camera field

pub struct HeroPlugin;

impl Plugin for HeroPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(Startup, setup_hero)
            .add_systems(Update, spin_hero);
    }
}

#[derive(Component)]
struct Hero;

fn setup_hero(mut commands: Commands, assets: Res<AssetServer>) {
    // 3D camera composited OVER the fluid (order 1, no clear-to-black). HDR + bloom
    // make the emissive neon core actually glow — the Layer-10 sibling of the
    // wallpaper bloom pass.
    let cam = commands
        .spawn((
            Camera3d::default(),
            Camera {
                order: 1,
                clear_color: ClearColorConfig::None,
                ..default()
            },
            Hdr,
            Tonemapping::TonyMcMapface,
            Bloom::NATURAL,
            Transform::from_xyz(4.6, 2.8, 5.2).looking_at(Vec3::ZERO, Vec3::Y),
        ))
        .id();
    // In wallpaper mode, mark the camera so bevy_live_wallpaper retargets it onto the
    // layer-shell surface (composited over the fluid's Camera2d, order 1, no clear).
    if std::env::var("NIMBUS_FLUX_WALLPAPER").is_ok() {
        commands
            .entity(cam)
            .insert(bevy_live_wallpaper::LiveWallpaperCamera);
    }
    // a soft key light — the hero is mostly emissive, but this catches any matte bits
    commands.spawn((
        DirectionalLight {
            illuminance: 3000.0,
            ..default()
        },
        Transform::from_xyz(3.0, 6.0, 4.0).looking_at(Vec3::ZERO, Vec3::Y),
    ));
    // the Blender-authored hero mesh (exported from the same scene as the wallpaper sprite)
    commands.spawn((
        SceneRoot(assets.load(GltfAssetLabel::Scene(0).from_asset("hero_core.glb"))),
        Transform::from_translation(Vec3::ZERO),
        Hero,
    ));
}

fn spin_hero(time: Res<Time>, mut q: Query<&mut Transform, With<Hero>>) {
    let dt = time.delta_secs();
    for mut t in &mut q {
        t.rotate_y(0.5 * dt);
    }
}
