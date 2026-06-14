//! Nimbus Flux — GPU compute Eulerian fluid plugin (bevy 0.18).
//!
//! Runs a stable-fluids (Jos Stam) Navier-Stokes solver entirely on the GPU as a
//! chain of compute passes in a single render-graph node. All passes share ONE
//! bind-group layout `(read, read, write, uniform)`; the per-pass texture routing
//! is set up in `prepare_bind_groups`. See `assets/shaders/fluid.wgsl`.

use bevy::{
    asset::RenderAssetUsages,
    core_pipeline::tonemapping::Tonemapping,
    input::ButtonInput,
    prelude::*,
    render::{
        extract_resource::{ExtractResource, ExtractResourcePlugin},
        render_asset::RenderAssets,
        render_graph::{self, RenderGraph, RenderLabel},
        render_resource::{
            binding_types::{texture_storage_2d, uniform_buffer},
            *,
        },
        renderer::{RenderContext, RenderDevice, RenderQueue},
        texture::GpuImage,
        Render, RenderApp, RenderStartup, RenderSystems,
    },
    shader::PipelineCacheError,
    window::PrimaryWindow,
};
use std::borrow::Cow;

/// Simulation grid resolution (texels). Window matches this 1:1 for v1.
pub const SIM: UVec2 = UVec2::new(1280, 720);
const WORKGROUP: u32 = 8;
const JACOBI_ITERS: usize = 30;
const SHADER_ASSET_PATH: &str = "shaders/fluid.wgsl";

pub struct FluidPlugin;

#[derive(Debug, Hash, PartialEq, Eq, Clone, RenderLabel)]
struct FluidLabel;

impl Plugin for FluidPlugin {
    fn build(&self, app: &mut App) {
        app.add_plugins((
            ExtractResourcePlugin::<FluidImages>::default(),
            ExtractResourcePlugin::<FluidConfig>::default(),
        ))
        .add_systems(Startup, setup)
        .add_systems(Update, (update_config, keyboard_controls));

        let render_app = app.sub_app_mut(RenderApp);
        render_app
            .add_systems(RenderStartup, init_pipeline)
            .add_systems(
                Render,
                prepare_bind_groups.in_set(RenderSystems::PrepareBindGroups),
            );

        let mut graph = render_app.world_mut().resource_mut::<RenderGraph>();
        graph.add_node(FluidLabel, FluidNode::default());
        graph.add_node_edge(FluidLabel, bevy::render::graph::CameraDriverLabel);
    }
}

// --- uniform shared by every pass ----------------------------------------
#[derive(Resource, Clone, Copy, ExtractResource, ShaderType)]
pub struct FluidConfig {
    sim: Vec2,
    mouse: Vec2,
    mouse_vel: Vec2,
    dye_color: Vec4, // rgb = injected colour, w = mouse_down
    palette0: Vec4,
    palette1: Vec4,
    palette2: Vec4,
    palette3: Vec4,
    params: Vec4,  // dt, vel_dissipation, dye_dissipation, time
    params2: Vec4, // splat_radius, force_scale, dark, style
}

impl FluidConfig {
    fn new() -> Self {
        // Optional env overrides so styles can be captured/launched headlessly.
        let envf = |k: &str, d: f32| {
            std::env::var(k)
                .ok()
                .and_then(|s| s.parse::<f32>().ok())
                .unwrap_or(d)
        };
        let style = envf("NIMBUS_FLUX_STYLE", 0.0);
        let dark = envf("NIMBUS_FLUX_DARK", 1.0);
        let lin = |hex: u32| {
            let r = ((hex >> 16) & 0xff) as u8;
            let g = ((hex >> 8) & 0xff) as u8;
            let b = (hex & 0xff) as u8;
            let c = Color::srgb_u8(r, g, b).to_linear();
            Vec4::new(c.red, c.green, c.blue, 1.0)
        };
        Self {
            sim: SIM.as_vec2(),
            mouse: SIM.as_vec2() * 0.5,
            mouse_vel: Vec2::ZERO,
            dye_color: Vec4::new(0.9, 0.95, 1.0, 0.0),
            // Big Sur stops, dark -> warm.
            palette0: lin(0x0d0f29),
            palette1: lin(0x1c2e73),
            palette2: lin(0x4552b8),
            palette3: lin(0xfa8c73),
            params: Vec4::new(1.0, 0.999, 0.992, 0.0),
            params2: Vec4::new(22.0, 1.0, dark, style),
        }
    }
}

// --- ping-pong textures ---------------------------------------------------
#[derive(Resource, Clone, ExtractResource)]
struct FluidImages {
    vel: Handle<Image>,
    dye: Handle<Image>,
    tmpv: Handle<Image>,
    tmpd: Handle<Image>,
    div: Handle<Image>,
    prs0: Handle<Image>,
    prs1: Handle<Image>,
    out: Handle<Image>,
}

fn make_image(images: &mut Assets<Image>, size: UVec2) -> Handle<Image> {
    let mut image = Image::new_target_texture(size.x, size.y, TextureFormat::Rgba32Float, None);
    image.asset_usage = RenderAssetUsages::RENDER_WORLD;
    image.texture_descriptor.usage =
        TextureUsages::COPY_DST | TextureUsages::STORAGE_BINDING | TextureUsages::TEXTURE_BINDING;
    images.add(image)
}

fn setup(mut commands: Commands, mut images: ResMut<Assets<Image>>) {
    let out = make_image(&mut images, SIM);
    commands.insert_resource(FluidImages {
        vel: make_image(&mut images, SIM),
        dye: make_image(&mut images, SIM),
        tmpv: make_image(&mut images, SIM),
        tmpd: make_image(&mut images, SIM),
        div: make_image(&mut images, SIM),
        prs0: make_image(&mut images, SIM),
        prs1: make_image(&mut images, SIM),
        out: out.clone(),
    });

    commands.insert_resource(FluidConfig::new());

    let cam2d = commands.spawn((Camera2d, Tonemapping::None)).id();
    // In wallpaper mode, mark the fluid camera so bevy_live_wallpaper retargets it onto
    // the layer-shell surface (the hero Camera3d composites over it at order 1).
    if std::env::var("NIMBUS_FLUX_WALLPAPER").is_ok() {
        commands
            .entity(cam2d)
            .insert(bevy_live_wallpaper::LiveWallpaperCamera);
    }
    commands.spawn((
        Sprite {
            image: out,
            custom_size: Some(SIM.as_vec2()),
            ..default()
        },
        Transform::default(),
    ));
}

// --- main-world: feed cursor + time into the uniform ----------------------
fn update_config(
    windows: Query<&Window, With<PrimaryWindow>>,
    mouse_btn: Res<ButtonInput<MouseButton>>,
    time: Res<Time>,
    mut config: ResMut<FluidConfig>,
    mut prev: Local<Option<Vec2>>,
) {
    config.params.w = time.elapsed_secs();
    config.dye_color.w = if mouse_btn.pressed(MouseButton::Left) {
        1.0
    } else {
        0.0
    };

    let Ok(win) = windows.single() else {
        return;
    };
    if let Some(cp) = win.cursor_position() {
        let m = Vec2::new(
            cp.x / win.width() * SIM.x as f32,
            cp.y / win.height() * SIM.y as f32,
        );
        let p = prev.unwrap_or(m);
        config.mouse = m;
        config.mouse_vel = (m - p).clamp_length_max(60.0);
        *prev = Some(m);
    } else {
        config.mouse_vel = Vec2::ZERO;
    }
}

/// Keys 1/2/3 = ink/mercury/water · D = light-dark · these drive params2.
fn keyboard_controls(keys: Res<ButtonInput<KeyCode>>, mut config: ResMut<FluidConfig>) {
    if keys.just_pressed(KeyCode::Digit1) {
        config.params2.w = 0.0;
    }
    if keys.just_pressed(KeyCode::Digit2) {
        config.params2.w = 1.0;
    }
    if keys.just_pressed(KeyCode::Digit3) {
        config.params2.w = 2.0;
    }
    if keys.just_pressed(KeyCode::KeyD) {
        config.params2.z = 1.0 - config.params2.z;
    }
}

// --- pipelines ------------------------------------------------------------
#[derive(Resource)]
struct FluidPipeline {
    layout: BindGroupLayoutDescriptor,
    advect_vel: CachedComputePipelineId,
    advect_dye: CachedComputePipelineId,
    splat_vel: CachedComputePipelineId,
    splat_dye: CachedComputePipelineId,
    divergence: CachedComputePipelineId,
    jacobi: CachedComputePipelineId,
    gradient_subtract: CachedComputePipelineId,
    copy: CachedComputePipelineId,
    render: CachedComputePipelineId,
}

impl FluidPipeline {
    fn all(&self) -> [CachedComputePipelineId; 9] {
        [
            self.advect_vel,
            self.advect_dye,
            self.splat_vel,
            self.splat_dye,
            self.divergence,
            self.jacobi,
            self.gradient_subtract,
            self.copy,
            self.render,
        ]
    }
}

fn init_pipeline(
    mut commands: Commands,
    asset_server: Res<AssetServer>,
    pipeline_cache: Res<PipelineCache>,
) {
    let layout = BindGroupLayoutDescriptor::new(
        "FluidLayout",
        &BindGroupLayoutEntries::sequential(
            ShaderStages::COMPUTE,
            (
                texture_storage_2d(TextureFormat::Rgba32Float, StorageTextureAccess::ReadOnly),
                texture_storage_2d(TextureFormat::Rgba32Float, StorageTextureAccess::ReadOnly),
                texture_storage_2d(TextureFormat::Rgba32Float, StorageTextureAccess::WriteOnly),
                uniform_buffer::<FluidConfig>(false),
            ),
        ),
    );
    let shader = asset_server.load(SHADER_ASSET_PATH);
    let mk = |entry: &'static str| {
        pipeline_cache.queue_compute_pipeline(ComputePipelineDescriptor {
            layout: vec![layout.clone()],
            shader: shader.clone(),
            entry_point: Some(Cow::Borrowed(entry)),
            ..default()
        })
    };

    commands.insert_resource(FluidPipeline {
        advect_vel: mk("advect_vel"),
        advect_dye: mk("advect_dye"),
        splat_vel: mk("splat_vel"),
        splat_dye: mk("splat_dye"),
        divergence: mk("divergence"),
        jacobi: mk("jacobi"),
        gradient_subtract: mk("gradient_subtract"),
        copy: mk("copy"),
        render: mk("render"),
        layout,
    });
}

// --- per-frame bind groups (one per pass, shared layout) ------------------
#[derive(Resource)]
struct FluidBindGroups {
    advect_vel: BindGroup,
    advect_dye: BindGroup,
    splat_vel: BindGroup,
    splat_dye: BindGroup,
    divergence: BindGroup,
    jacobi_a: BindGroup,
    jacobi_b: BindGroup,
    gradient_subtract: BindGroup,
    copy: BindGroup,
    render: BindGroup,
}

fn prepare_bind_groups(
    mut commands: Commands,
    pipeline: Res<FluidPipeline>,
    gpu_images: Res<RenderAssets<GpuImage>>,
    images: Res<FluidImages>,
    config: Res<FluidConfig>,
    render_device: Res<RenderDevice>,
    pipeline_cache: Res<PipelineCache>,
    queue: Res<RenderQueue>,
) {
    macro_rules! view {
        ($h:expr) => {
            match gpu_images.get(&$h) {
                Some(g) => &g.texture_view,
                None => return, // textures not uploaded yet — try again next frame
            }
        };
    }
    let vel = view!(images.vel);
    let dye = view!(images.dye);
    let tmpv = view!(images.tmpv);
    let tmpd = view!(images.tmpd);
    let div = view!(images.div);
    let prs0 = view!(images.prs0);
    let prs1 = view!(images.prs1);
    let out = view!(images.out);

    let mut ub = UniformBuffer::from(config.into_inner());
    ub.write_buffer(&render_device, &queue);

    let layout = pipeline_cache.get_bind_group_layout(&pipeline.layout);
    let make = |a: &TextureView, b: &TextureView, d: &TextureView| {
        render_device.create_bind_group(
            None,
            &layout,
            &BindGroupEntries::sequential((a, b, d, &ub)),
        )
    };

    commands.insert_resource(FluidBindGroups {
        advect_vel: make(vel, vel, tmpv),
        splat_vel: make(tmpv, tmpv, vel),
        divergence: make(vel, vel, div),
        jacobi_a: make(prs0, div, prs1),
        jacobi_b: make(prs1, div, prs0),
        gradient_subtract: make(vel, prs0, tmpv),
        copy: make(tmpv, tmpv, vel),
        advect_dye: make(vel, dye, tmpd),
        splat_dye: make(tmpd, tmpd, dye),
        render: make(dye, vel, out),
    });
}

// --- render-graph node: dispatch the solver each frame --------------------
enum FluidState {
    Loading,
    Ready,
}

struct FluidNode {
    state: FluidState,
}

impl Default for FluidNode {
    fn default() -> Self {
        Self {
            state: FluidState::Loading,
        }
    }
}

impl render_graph::Node for FluidNode {
    fn update(&mut self, world: &mut World) {
        let pipeline = world.resource::<FluidPipeline>();
        let cache = world.resource::<PipelineCache>();
        if let FluidState::Loading = self.state {
            let mut ready = true;
            for id in pipeline.all() {
                match cache.get_compute_pipeline_state(id) {
                    CachedPipelineState::Ok(_) => {}
                    CachedPipelineState::Err(PipelineCacheError::ShaderNotLoaded(_)) => {
                        ready = false;
                    }
                    CachedPipelineState::Err(err) => {
                        panic!("Compiling {SHADER_ASSET_PATH}:\n{err}")
                    }
                    _ => ready = false,
                }
            }
            if ready {
                self.state = FluidState::Ready;
            }
        }
    }

    fn run(
        &self,
        _graph: &mut render_graph::RenderGraphContext,
        render_context: &mut RenderContext,
        world: &World,
    ) -> Result<(), render_graph::NodeRunError> {
        if let FluidState::Loading = self.state {
            return Ok(());
        }
        let Some(bind) = world.get_resource::<FluidBindGroups>() else {
            return Ok(());
        };
        let cache = world.resource::<PipelineCache>();
        let pipeline = world.resource::<FluidPipeline>();

        let wx = SIM.x.div_ceil(WORKGROUP);
        let wy = SIM.y.div_ceil(WORKGROUP);

        let mut pass = render_context
            .command_encoder()
            .begin_compute_pass(&ComputePassDescriptor::default());

        // helper: set pipeline + bind group, dispatch the whole grid
        macro_rules! dispatch {
            ($pid:expr, $bg:expr) => {{
                let Some(p) = cache.get_compute_pipeline($pid) else {
                    return Ok(());
                };
                pass.set_pipeline(p);
                pass.set_bind_group(0, $bg, &[]);
                pass.dispatch_workgroups(wx, wy, 1);
            }};
        }

        // velocity: advect -> add forces
        dispatch!(pipeline.advect_vel, &bind.advect_vel);
        dispatch!(pipeline.splat_vel, &bind.splat_vel);
        // projection: divergence -> jacobi pressure -> subtract gradient
        dispatch!(pipeline.divergence, &bind.divergence);
        for i in 0..JACOBI_ITERS {
            let bg = if i % 2 == 0 {
                &bind.jacobi_a
            } else {
                &bind.jacobi_b
            };
            dispatch!(pipeline.jacobi, bg);
        }
        dispatch!(pipeline.gradient_subtract, &bind.gradient_subtract);
        dispatch!(pipeline.copy, &bind.copy);
        // dye: advect by the projected velocity -> inject colour
        dispatch!(pipeline.advect_dye, &bind.advect_dye);
        dispatch!(pipeline.splat_dye, &bind.splat_dye);
        // present
        dispatch!(pipeline.render, &bind.render);

        Ok(())
    }
}
