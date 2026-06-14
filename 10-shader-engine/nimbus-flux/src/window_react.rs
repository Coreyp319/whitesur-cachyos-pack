//! Shared window-move reactivity for the Layer-10 scenes.
//!
//! Reads the Layer-9 `windows.json` bridge (the same KWin→file feed the QML aurora
//! uses) and turns a *dragged* window's motion into a debounced, spring-smoothed
//! `yaw`/`pitch` a camera can lean toward — so the view turns in the direction the
//! window was moved, then eases back. Pipeline: raw window centre → low-pass (input
//! debounce) → differentiate the smoothed centre *only while dragging* → deadzone +
//! clamp (kill jitter/snap spikes) → low-pass the velocity → critically-damped spring.
//!
//! Requires the Layer-9 window bridge to be running (`windows-apply.sh`); without it
//! the file is absent and the camera simply never leans.

use bevy::prelude::*;

/// Spring-smoothed window-drag lean. `yaw` (+ = window moved right) and `pitch`
/// (+ = window moved down) are read by scenes; the rest is internal filter state.
#[derive(Resource, Default)]
pub struct WindowReact {
    pub yaw: f32,
    pub pitch: f32,
    pub moving: bool,
    yaw_v: f32,
    pitch_v: f32,
    tgt: Vec2,
    center_smooth: Vec2,
    prev_smooth: Vec2,
    seeded: bool,
}

pub struct WindowReactPlugin;

impl Plugin for WindowReactPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<WindowReact>()
            .add_systems(Update, poll_windows);
    }
}

/// Semi-implicit critically-damped spring step — no overshoot, frame-rate independent.
fn spring(x: &mut f32, v: &mut f32, target: f32, omega: f32, dt: f32) {
    let accel = omega * omega * (target - *x) - 2.0 * omega * *v;
    *v += accel * dt;
    *x += *v * dt;
}

fn poll_windows(time: Res<Time>, react: ResMut<WindowReact>) {
    let dt = time.delta_secs().clamp(1e-4, 0.1); // clamp for spring/derivative stability
    let react = react.into_inner();

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

#[cfg(test)]
mod tests {
    //! Headless checks for the direction/sign of the reactivity chain (no GPU/window),
    //! so the camera-lean direction is verifiable even where windowed rendering is
    //! flaky (NVIDIA + Wayland swapchain timeouts).
    use super::*;

    #[test]
    fn spring_settles_toward_target_with_matching_sign() {
        let (mut x, mut v) = (0.0_f32, 0.0_f32);
        for _ in 0..400 {
            spring(&mut x, &mut v, 1.0, 7.0, 1.0 / 60.0);
        }
        assert!((x - 1.0).abs() < 0.02, "spring should settle near target, got {x}");

        let (mut xn, mut vn) = (0.0_f32, 0.0_f32);
        spring(&mut xn, &mut vn, -3.0, 7.0, 1.0 / 60.0);
        assert!(xn < 0.0, "negative target must drive x negative, got {xn}");
    }

    #[test]
    fn dragged_window_center_sign_follows_screen_position() {
        // isolate XDG_RUNTIME_DIR to a temp dir so we drive read_active_center directly
        let dir = std::env::temp_dir().join(format!("nimbus-hexreact-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("nimbus-aurora")).unwrap();
        std::env::set_var("XDG_RUNTIME_DIR", &dir);
        let path = dir.join("nimbus-aurora/windows.json");

        // a window dragged to the RIGHT of a 3440-wide screen → +x, moving == true
        std::fs::write(
            &path,
            r#"{"wins":[{"x":0,"y":0,"w":3440,"h":1440,"active":false,"moving":false}],
               "move":{"x":2400,"y":600,"w":800,"h":600,"active":true,"moving":true}}"#,
        )
        .unwrap();
        let (c, moving) = read_active_center().expect("should parse dragged window");
        assert!(moving, "a non-null `move` means a drag is in progress");
        assert!(c.x > 0.0, "right-of-centre drag → +x (camera leans right), got {}", c.x);

        // a window dragged to the LEFT → -x
        std::fs::write(
            &path,
            r#"{"wins":[{"x":0,"y":0,"w":3440,"h":1440,"active":false,"moving":false}],
               "move":{"x":120,"y":600,"w":800,"h":600,"active":true,"moving":true}}"#,
        )
        .unwrap();
        let (c2, _) = read_active_center().expect("should parse");
        assert!(c2.x < 0.0, "left-of-centre drag → -x (camera leans left), got {}", c2.x);

        std::fs::remove_dir_all(&dir).ok();
    }
}
