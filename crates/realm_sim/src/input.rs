//! What a player sends every simulation step. Already quantized: the client
//! predicts with exactly the numbers the server will receive.

use crate::Vec3;
use crate::mathx::yaw_axes;

/// One step of player intent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct MoveInput {
    /// Strafe, -127 (left) ..= 127 (right).
    pub strafe: i8,
    /// Forward, -127 (back) ..= 127 (forward).
    pub forward: i8,
    /// Camera yaw, a full turn in 65 536 steps (0 = looking along -Z).
    pub yaw: u16,
    /// [`MoveInput::JUMP`] and friends.
    pub buttons: u8,
}

impl MoveInput {
    /// Held jump (also "rise" on the broom and "paddle up" in water).
    pub const JUMP: u8 = 1 << 0;
    /// Held descend on the broom.
    pub const DESCEND: u8 = 1 << 1;

    /// No steering, no buttons, same view.
    #[must_use]
    pub fn neutral(yaw: u16) -> Self {
        Self {
            yaw,
            ..Self::default()
        }
    }

    #[must_use]
    pub fn held(self, button: u8) -> bool {
        self.buttons & button != 0
    }

    /// Yaw in radians.
    #[must_use]
    pub fn yaw_radians(self) -> f32 {
        f32::from(self.yaw) * (core::f32::consts::TAU / 65_536.0)
    }

    /// Builds the quantized form of a stick/keyboard vector (`x` right,
    /// `y` forward, each in -1..=1, longer vectors are clamped to unit length)
    /// and a yaw in radians.
    #[must_use]
    pub fn from_intent(x: f32, y: f32, yaw_radians: f32, buttons: u8) -> Self {
        let (mut x, mut y) = (finite_or_zero(x), finite_or_zero(y));
        let len_sq = x * x + y * y;
        if len_sq > 1.0 {
            let len = libm::sqrtf(len_sq);
            x /= len;
            y /= len;
        }
        let turn = libm::fmodf(finite_or_zero(yaw_radians), core::f32::consts::TAU);
        let turn = if turn < 0.0 {
            turn + core::f32::consts::TAU
        } else {
            turn
        };
        Self {
            strafe: quantize_axis(x),
            forward: quantize_axis(y),
            yaw: (libm::roundf(turn * (65_536.0 / core::f32::consts::TAU)) as u32 & 0xFFFF) as u16,
            buttons,
        }
    }

    /// World-space planar direction of the steering, unit length or zero.
    #[must_use]
    pub fn direction(self) -> Vec3 {
        if self.strafe == 0 && self.forward == 0 {
            return Vec3::ZERO;
        }
        let (forward, right) = yaw_axes(self.yaw_radians());
        let x = f32::from(self.strafe) / 127.0;
        let y = f32::from(self.forward) / 127.0;
        (right * x + forward * y).normalize_or_zero()
    }
}

fn finite_or_zero(v: f32) -> f32 {
    if v.is_finite() { v } else { 0.0 }
}

fn quantize_axis(v: f32) -> i8 {
    libm::roundf(v.clamp(-1.0, 1.0) * 127.0) as i8
}
