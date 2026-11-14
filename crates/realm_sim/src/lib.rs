//! Shared game rules. Everything in here must behave the same on the map
//! servers, in the Godot client (prediction) and in the headless bots, so it
//! never touches Godot types, wall-clock time or platform APIs.
//!
//! Determinism: the same inputs from the same state give bit-identical results
//! on every platform the game ships on. That rules out platform `libm` (trig
//! goes through the pure-Rust `libm` crate), fused multiply-add, and SIMD paths
//! that reorder operations (parry3d runs with `enhanced-determinism`). State is
//! snapped to the wire grid after every step, so a client that rewinds to a
//! server snapshot resumes from exactly the server's numbers.

pub mod gates;
pub mod input;
pub mod movement;
pub mod nav;
pub mod pack;
pub mod staircase;
pub mod world;

mod mathx;

pub use mathx::GRID as WIRE_GRID;
pub use parry3d::math::Vec3;

/// Simulation steps per second on every side.
pub const SIM_HZ: u32 = 30;

/// Length of one simulation step in seconds.
pub const SIM_DT: f32 = 1.0 / SIM_HZ as f32;

/// A simulation step number. Wraps after ~4.5 years at 30 Hz.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Tick(pub u32);

impl Tick {
    #[must_use]
    pub fn next(self) -> Self {
        Self(self.0.wrapping_add(1))
    }
}

/// Turns variable frame time into whole simulation steps. The leftover
/// fraction (`alpha`) is what the client uses to draw between two steps.
#[derive(Clone, Debug, Default)]
pub struct FixedStep {
    accumulator: f32,
}

impl FixedStep {
    /// The most steps one frame may run; a longer stall is dropped instead of
    /// spiralling (the server's snapshot corrects the client afterwards).
    pub const MAX_STEPS_PER_FRAME: u32 = 8;

    /// Adds `frame_seconds` and returns how many steps to run now.
    pub fn advance(&mut self, frame_seconds: f32) -> u32 {
        self.accumulator += frame_seconds.max(0.0);
        let mut steps = 0;
        while self.accumulator >= SIM_DT && steps < Self::MAX_STEPS_PER_FRAME {
            self.accumulator -= SIM_DT;
            steps += 1;
        }
        if steps == Self::MAX_STEPS_PER_FRAME {
            self.accumulator = self.accumulator.min(SIM_DT);
        }
        steps
    }

    /// Fraction of the next step already elapsed, in `0.0..1.0`.
    #[must_use]
    pub fn alpha(&self) -> f32 {
        (self.accumulator / SIM_DT).clamp(0.0, 1.0)
    }
}
