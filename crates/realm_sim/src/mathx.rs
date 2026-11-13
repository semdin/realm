//! Small deterministic helpers. Trig goes through the pure-Rust `libm` so the
//! result never depends on the platform's C library.

use crate::Vec3;

/// Moves `from` toward `to` by at most `delta` (Godot's `move_toward`).
pub fn move_toward(from: f32, to: f32, delta: f32) -> f32 {
    if (to - from).abs() <= delta {
        to
    } else if to > from {
        from + delta
    } else {
        from - delta
    }
}

/// Planar unit vectors for a camera yaw in radians: (forward, right). Forward
/// is -Z at yaw 0, matching the old game's camera convention.
pub fn yaw_axes(yaw: f32) -> (Vec3, Vec3) {
    let (s, c) = (libm::sinf(yaw), libm::cosf(yaw));
    (Vec3::new(-s, 0.0, -c), Vec3::new(c, 0.0, -s))
}

/// Grid every replicated length and speed snaps to: 1/256 m (about 4 mm).
/// A power of two, so snapping is exact in binary floating point.
pub const GRID: f32 = 256.0;

/// Snaps a value to the wire grid.
pub fn snap(value: f32) -> f32 {
    libm::roundf(value * GRID) / GRID
}

pub fn snap_vec(v: Vec3) -> Vec3 {
    Vec3::new(snap(v.x), snap(v.y), snap(v.z))
}
