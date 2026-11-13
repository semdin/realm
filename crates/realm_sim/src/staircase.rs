//! The castle's moving staircases (port of the old game's HPStaircase).
//!
//! A flight docks at one landing, warns, swings to its next dock and docks
//! again, round and round. Nothing a player does changes that, so a flight's
//! whole state is a pure function of the simulation tick: the server and every
//! client compute the same pose on the same tick and nothing is replicated
//! beyond the tick itself. Each flight brings colliders the rule switches:
//! the deck and its railings move with it, its end gates close while it is not
//! docked, and the gate across each landing it serves is shut while the flight
//! is anywhere else. A body standing on a moving deck is carried with it.

use parry3d::math::{Pose, Rot3};
use parry3d::shape::SharedShape;
use serde::Deserialize;

use crate::movement::Body;
use crate::world::World;
use crate::{SIM_HZ, Vec3};

/// One flight as the map catalog (`maps.json` `staircases`) describes it.
#[derive(Clone, Debug, Deserialize)]
pub struct StaircaseSpec {
    pub id: u32,
    pub map_id: String,
    #[serde(default)]
    pub origin: [f32; 3],
    /// The vertical axis a swinging flight turns about, staircase-local [x, z].
    pub pivot: Option<[f32; 2]>,
    pub flight: Flight,
    pub timing: Timing,
    #[serde(default)]
    pub start_delay_ms: u32,
    pub docks: Vec<Dock>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Flight {
    pub rise: f32,
    pub run: f32,
    pub width: f32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Timing {
    pub dwell_ms: u32,
    pub warning_ms: u32,
    pub moving_ms: u32,
    pub docking_ms: u32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Dock {
    pub id: String,
    pub bottom: [f32; 3],
    /// Degrees about +Y.
    pub yaw: f32,
    pub bottom_landing: [f32; 3],
    pub top_landing: [f32; 3],
    /// Which ends of this dock's landings carry a gate ("bottom", "top").
    #[serde(default = "both_ends")]
    pub gates: Vec<String>,
}

fn both_ends() -> Vec<String> {
    vec!["bottom".to_owned(), "top".to_owned()]
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Docked,
    Warning,
    Moving,
    Docking,
}

/// Where a flight is in its cycle.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StairState {
    pub phase: Phase,
    /// The dock it is at, or leaving.
    pub from: usize,
    /// The dock it is heading to (equals `from` while docked).
    pub to: usize,
    pub move_start: f64,
    pub arrive: f64,
}

/// A pose on the ground plane: position and yaw about +Y (radians).
#[derive(Clone, Copy, Debug, PartialEq)]
struct YawPose {
    origin: Vec3,
    yaw: f32,
}

/// Rotates `v` about +Y by `yaw` (right-handed: +X turns toward -Z).
fn rot_y(v: Vec3, yaw: f32) -> Vec3 {
    let (s, c) = (libm::sinf(yaw), libm::cosf(yaw));
    Vec3::new(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
}

fn quat_y(yaw: f32) -> Rot3 {
    Rot3::from_xyzw(0.0, libm::sinf(yaw * 0.5), 0.0, libm::cosf(yaw * 0.5))
}

fn quat_x(angle: f32) -> Rot3 {
    Rot3::from_xyzw(libm::sinf(angle * 0.5), 0.0, 0.0, libm::cosf(angle * 0.5))
}

/// Shortest signed turn from `a` to `b`, radians.
fn turn(a: f32, b: f32) -> f32 {
    let tau = core::f32::consts::TAU;
    let d = libm::fmodf(b - a, tau);
    if d > core::f32::consts::PI {
        d - tau
    } else if d < -core::f32::consts::PI {
        d + tau
    } else {
        d
    }
}

fn ticks(ms: u32) -> f64 {
    (libm::round(f64::from(ms) * f64::from(SIM_HZ) / 1000.0)).max(1.0)
}

/// A box the rule places: half extents, and where it sits in its frame.
#[derive(Clone, Copy)]
struct Part {
    half: Vec3,
    at: Vec3,
    /// Rotation about X (the ramp tilt), radians.
    tilt: f32,
}

/// One flight placed in a map.
pub struct Staircase {
    spec: StaircaseSpec,
    anchor: YawPose,
    dwell: f64,
    warning: f64,
    moving: f64,
    docking: f64,
    delay: f64,
    deck: [Part; 3],
    end_gates: [Part; 2],
    /// (dock, part in that dock's frame) for every landing gate.
    landing_gates: Vec<(usize, Part)>,
    shapes: Vec<SharedShape>,
}

impl Staircase {
    /// `anchor` is where the staircase node stands in the map (yaw-only).
    #[must_use]
    pub fn new(spec: StaircaseSpec, anchor_translation: Vec3, anchor_yaw: f32) -> Self {
        let f = &spec.flight;
        let angle = libm::atan2f(f.rise, f.run);
        let ramp = libm::sqrtf(f.rise * f.rise + f.run * f.run);
        let mid = Vec3::new(0.0, f.rise * 0.5, f.run * 0.5);
        let up = Vec3::new(0.0, libm::cosf(angle), -libm::sinf(angle));
        let half_w = f.width * 0.5;
        let deck = [
            Part {
                half: Vec3::new(half_w, 0.15, ramp * 0.5),
                at: mid - up * 0.15,
                tilt: -angle,
            },
            Part {
                half: Vec3::new(0.08, 0.55, ramp * 0.5),
                at: mid + up * 0.55 + Vec3::new(-(half_w + 0.12), 0.0, 0.0),
                tilt: -angle,
            },
            Part {
                half: Vec3::new(0.08, 0.55, ramp * 0.5),
                at: mid + up * 0.55 + Vec3::new(half_w + 0.12, 0.0, 0.0),
                tilt: -angle,
            },
        ];
        let end_gates = [
            Part {
                half: Vec3::new(half_w, 0.8, 0.1),
                at: Vec3::new(0.0, 0.8, -0.15),
                tilt: 0.0,
            },
            Part {
                half: Vec3::new(half_w, 0.8, 0.1),
                at: Vec3::new(0.0, f.rise + 0.8, f.run + 0.15),
                tilt: 0.0,
            },
        ];
        let mut landing_gates = Vec::new();
        for (i, dock) in spec.docks.iter().enumerate() {
            for end in &dock.gates {
                let at = if end == "bottom" {
                    Vec3::new(0.0, 0.6, -0.15)
                } else {
                    Vec3::new(0.0, f.rise + 0.6, f.run + 0.15)
                };
                landing_gates.push((
                    i,
                    Part {
                        half: Vec3::new(half_w, 0.6, 0.15),
                        at,
                        tilt: 0.0,
                    },
                ));
            }
        }
        let shapes = deck
            .iter()
            .chain(end_gates.iter())
            .chain(landing_gates.iter().map(|(_, p)| p))
            .map(|p| SharedShape::cuboid(p.half.x, p.half.y, p.half.z))
            .collect();
        let t = &spec.timing;
        Self {
            dwell: ticks(t.dwell_ms),
            warning: ticks(t.warning_ms),
            moving: ticks(t.moving_ms),
            docking: ticks(t.docking_ms),
            delay: if spec.start_delay_ms == 0 {
                0.0
            } else {
                ticks(spec.start_delay_ms)
            },
            anchor: YawPose {
                origin: anchor_translation,
                yaw: anchor_yaw,
            },
            deck,
            end_gates,
            landing_gates,
            shapes,
            spec,
        }
    }

    #[must_use]
    pub fn id(&self) -> u32 {
        self.spec.id
    }

    /// The flight's state at `tick` (fractional ticks for drawing between two).
    #[must_use]
    pub fn state_at(&self, tick: f64) -> StairState {
        let n = self.spec.docks.len().max(1);
        let t = tick - self.delay;
        if t < 0.0 {
            return StairState {
                phase: Phase::Docked,
                from: 0,
                to: 0,
                move_start: 0.0,
                arrive: 0.0,
            };
        }
        let cycle = self.dwell + self.warning + self.moving + self.docking;
        let k = libm::floor(t / cycle);
        let base = self.delay + k * cycle;
        let r = tick - base;
        let from = (k as u64 % n as u64) as usize;
        let to = (from + 1) % n;
        let move_start = base + self.dwell + self.warning;
        let arrive = move_start + self.moving + self.docking;
        let phase = if r < self.dwell {
            Phase::Docked
        } else if r < self.dwell + self.warning {
            Phase::Warning
        } else if r < self.dwell + self.warning + self.moving {
            Phase::Moving
        } else {
            Phase::Docking
        };
        let to = if phase == Phase::Docked { from } else { to };
        StairState {
            phase,
            from,
            to,
            move_start,
            arrive,
        }
    }

    fn dock_pose(&self, i: usize) -> YawPose {
        let d = &self.spec.docks[i % self.spec.docks.len()];
        let o = self.spec.origin;
        YawPose {
            origin: Vec3::new(d.bottom[0] - o[0], d.bottom[1] - o[1], d.bottom[2] - o[2]),
            yaw: d.yaw.to_radians(),
        }
    }

    /// Between two dock poses: swung about the pivot (the old game's path)
    /// or, without one, straight.
    fn between(&self, a: YawPose, b: YawPose, t: f32) -> YawPose {
        let yaw = a.yaw + turn(a.yaw, b.yaw) * t;
        match self.spec.pivot {
            Some([px, pz]) => {
                let axis = Vec3::new(px, a.origin.y, pz);
                let height = (b.origin.y - a.origin.y) * t;
                YawPose {
                    origin: axis
                        + Vec3::new(0.0, height, 0.0)
                        + rot_y(a.origin - axis, yaw - a.yaw),
                    yaw,
                }
            }
            None => YawPose {
                origin: a.origin + (b.origin - a.origin) * t,
                yaw,
            },
        }
    }

    /// The deck's pose in the staircase frame at `tick`.
    fn deck_local(&self, tick: f64) -> YawPose {
        let s = self.state_at(tick);
        let (a, b) = (self.dock_pose(s.from), self.dock_pose(s.to));
        match s.phase {
            Phase::Docked | Phase::Warning => a,
            Phase::Moving | Phase::Docking => {
                let whole = (s.arrive - s.move_start).max(1.0);
                let u = ((tick - s.move_start) / whole).clamp(0.0, 1.0) as f32;
                let eased = u * u * u * (u * (u * 6.0 - 15.0) + 10.0);
                self.between(a, b, eased)
            }
        }
    }

    fn to_map(&self, p: YawPose) -> YawPose {
        YawPose {
            origin: self.anchor.origin + rot_y(p.origin, self.anchor.yaw),
            yaw: self.anchor.yaw + p.yaw,
        }
    }

    fn part_pose(frame: YawPose, part: &Part) -> Pose {
        Pose::from_parts(
            frame.origin + rot_y(part.at, frame.yaw),
            quat_y(frame.yaw) * quat_x(part.tilt),
        )
    }

    /// Every collider of this flight that is solid at `tick`, with its shape.
    fn solid_at(&self, tick: f64, out: &mut Vec<(Pose, SharedShape)>) {
        let s = self.state_at(tick);
        let deck = self.to_map(self.deck_local(tick));
        let mut shape = self.shapes.iter();
        for part in &self.deck {
            out.push((
                Self::part_pose(deck, part),
                shape
                    .next()
                    .cloned()
                    .unwrap_or_else(|| SharedShape::ball(0.0)),
            ));
        }
        let gates_closed = s.phase != Phase::Docked;
        for part in &self.end_gates {
            let sh = shape.next().cloned();
            if gates_closed && let Some(sh) = sh {
                out.push((Self::part_pose(deck, part), sh));
            }
        }
        for (dock, part) in &self.landing_gates {
            let sh = shape.next().cloned();
            let open = s.phase == Phase::Docked && s.from == *dock;
            if !open && let Some(sh) = sh {
                out.push((
                    Self::part_pose(self.to_map(self.dock_pose(*dock)), part),
                    sh,
                ));
            }
        }
    }

    /// Deck-local coordinates (x across, y up, z along the run) of a map point.
    fn deck_space(&self, tick: f64, p: Vec3) -> Vec3 {
        let deck = self.to_map(self.deck_local(tick));
        rot_y(p - deck.origin, -deck.yaw)
    }

    /// A deck-local point (x across, y up, z along the run) in map space.
    #[must_use]
    pub fn deck_point(&self, tick: f64, local: Vec3) -> Vec3 {
        let deck = self.to_map(self.deck_local(tick));
        deck.origin + rot_y(local, deck.yaw)
    }

    fn slope(&self) -> f32 {
        if self.spec.flight.run.abs() < 1e-6 {
            0.0
        } else {
            self.spec.flight.rise / self.spec.flight.run
        }
    }

    /// Is a map point standing on the deck at `tick`?
    #[must_use]
    pub fn on_deck(&self, tick: f64, p: Vec3) -> bool {
        let local = self.deck_space(tick, p);
        let f = &self.spec.flight;
        if local.x.abs() > f.width * 0.5 + 0.35 || local.z < 0.2 || local.z > f.run - 0.2 {
            return false;
        }
        let surface = local.z * self.slope();
        local.y >= surface - 0.8 && local.y <= surface + 2.6
    }

    /// Carries a body standing on the deck from `tick - 1` to `tick`: kept at
    /// the same place on the deck, inside the railings, above the surface.
    pub fn carry(&self, body: &mut Body, tick: u32) {
        if tick == 0 || self.state_at(f64::from(tick)).phase == Phase::Docked {
            return;
        }
        let before = f64::from(tick - 1);
        if !self.on_deck(before, body.pos) {
            return;
        }
        let f = &self.spec.flight;
        let mut local = self.deck_space(before, body.pos);
        local.x = local.x.clamp(-f.width * 0.5 + 0.35, f.width * 0.5 - 0.35);
        local.z = local.z.clamp(0.3, f.run - 0.3);
        let surface = local.z * self.slope();
        local.y = local.y.clamp(surface + 0.05, surface + 2.4);
        body.pos = self.deck_point(f64::from(tick), local);
        if body.vel.y < 0.0 {
            body.vel.y = 0.0;
        }
    }
}

/// All flights of one map.
#[derive(Default)]
pub struct Staircases {
    pub flights: Vec<Staircase>,
    scratch: Vec<(Pose, SharedShape)>,
}

impl Staircases {
    #[must_use]
    pub fn new(flights: Vec<Staircase>) -> Self {
        Self {
            flights,
            scratch: Vec::new(),
        }
    }

    /// Puts every flight's solid colliders for `tick` into the world's moving
    /// set (replacing the previous tick's).
    pub fn apply(&mut self, world: &mut World, tick: u32) {
        self.scratch.clear();
        for flight in &self.flights {
            flight.solid_at(f64::from(tick), &mut self.scratch);
        }
        world.set_moving(&self.scratch);
    }

    /// Carries a body on any moving deck from the previous tick to `tick`.
    pub fn carry(&self, body: &mut Body, tick: u32) {
        for flight in &self.flights {
            flight.carry(body, tick);
        }
    }
}
