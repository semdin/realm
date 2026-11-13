//! Player movement: walking, jumping, stairs, steep slopes, swimming and the
//! broom. One call to [`step`] is one simulation tick. The server runs it with
//! the inputs it receives, the client runs it to predict its own body, and the
//! two agree bit for bit because both start from the same snapped state.
//!
//! Tuning comes from the old game (player.gd / rules.gd, 2026-11-13) so the
//! feel carries over; times are whole ticks at [`SIM_HZ`](crate::SIM_HZ).

use parry3d::shape::Capsule;

use crate::input::MoveInput;
use crate::mathx::{move_toward, snap, snap_vec};
use crate::world::{SweepHit, World};
use crate::{SIM_DT, Vec3};

pub const CAPSULE_RADIUS: f32 = 0.35;
pub const CAPSULE_HEIGHT: f32 = 1.85;

pub const GRAVITY: f32 = 24.0;
pub const JUMP_VELOCITY: f32 = 8.0;
pub const WALK_SPEED: f32 = 6.5;
pub const MOUNTED_SPEED: f32 = 12.0;
pub const SWIM_SPEED: f32 = 4.2;
pub const GROUND_ACCEL: f32 = 65.0;
pub const GROUND_STOP_DECEL: f32 = 180.0;
pub const MOUNTED_ACCEL: f32 = 25.0;
pub const SWIM_ACCEL: f32 = 18.0;
/// Airborne and flying bodies coast: they slow at this many times their top
/// speed per second when the stick is released.
pub const COAST_DECEL_FACTOR: f32 = 12.0;

pub const MOUNTED_VERTICAL_SPEED: f32 = 7.0;
pub const MOUNTED_VERTICAL_ACCEL: f32 = 18.0;
/// The broom holds itself this high over the ground when not climbing.
pub const HOVER_CLEARANCE: f32 = 1.45;
const HOVER_GAIN: f32 = 1.6;
const HOVER_MAX_LIFT: f32 = 0.5;
const HOVER_PROBE: f32 = 3.0;

/// Cosine of the steepest walkable slope (48 degrees).
pub const FLOOR_MIN_NORMAL_Y: f32 = 0.669_130_6;
pub const FLOOR_SNAP_LENGTH: f32 = 0.45;
pub const STEP_UP_HEIGHT: f32 = 0.45;
const STEP_UP_PROBE: f32 = 0.4;
const STEP_UP_MIN_SPEED: f32 = 0.6;
pub const STEEP_SLIDE_ACCEL: f32 = 14.0;
pub const STEEP_SLIDE_MAX: f32 = 7.5;
pub const SHOVE_DECAY: f32 = 26.0;

/// A press is remembered this long, so a press just before landing jumps.
pub const JUMP_BUFFER_TICKS: u8 = 6;
/// Just off the ground (a bump, a step down) still counts as ground.
pub const COYOTE_TICKS: u16 = 5;
const STEEP_MEMORY_TICKS: u8 = 5;

/// The swimmer floats this far under the surface.
pub const SWIM_FLOAT_DEPTH: f32 = 0.35;
const SWIM_ENTER_BAND: f32 = 0.7;
const SWIM_MAX_DEPTH: f32 = 3.0;
const SWIM_PADDLE_LIFT: f32 = 0.6;

/// Gap kept between the capsule and anything it touches.
const SKIN: f32 = 0.01;
const MAX_SLIDES: usize = 4;

/// Per-player numbers that come from equipment, effects and control state.
#[derive(Clone, Copy, Debug)]
pub struct MoveParams {
    /// On-foot speed with item and effect modifiers already applied.
    pub walk_speed: f32,
    pub mounted_speed: f32,
    pub swim_speed: f32,
    /// False while stunned, thrown or committed to an attack.
    pub can_steer: bool,
    pub can_jump: bool,
}

impl Default for MoveParams {
    fn default() -> Self {
        Self {
            walk_speed: WALK_SPEED,
            mounted_speed: MOUNTED_SPEED,
            swim_speed: SWIM_SPEED,
            can_steer: true,
            can_jump: true,
        }
    }
}

/// Everything about a moving body that the next tick depends on. Replicated to
/// its owner whole, so a rewind resumes from the server's exact state.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Body {
    /// Feet position.
    pub pos: Vec3,
    pub vel: Vec3,
    /// Knock-back velocity added on top of steering, decaying to zero.
    pub shove: Vec3,
    pub steep_normal: Vec3,
    pub slide_speed: f32,
    pub on_floor: bool,
    pub mounted: bool,
    pub swimming: bool,
    pub prev_jump: bool,
    pub air_ticks: u16,
    pub jump_buffer: u8,
    pub steep_ticks: u8,
}

impl Body {
    #[must_use]
    pub fn at(pos: Vec3) -> Self {
        Self {
            pos: snap_vec(pos),
            ..Self::default()
        }
    }

    fn center(&self) -> Vec3 {
        self.pos + Vec3::new(0.0, CAPSULE_HEIGHT * 0.5, 0.0)
    }

    /// Snaps every continuous value to the wire grid.
    fn snap(&mut self) {
        self.pos = snap_vec(self.pos);
        self.vel = snap_vec(self.vel);
        self.shove = snap_vec(self.shove);
        self.steep_normal = snap_vec(self.steep_normal);
        self.slide_speed = snap(self.slide_speed);
    }
}

fn capsule() -> Capsule {
    Capsule::new_y(CAPSULE_HEIGHT * 0.5 - CAPSULE_RADIUS, CAPSULE_RADIUS)
}

/// Advances `body` by one tick.
pub fn step(body: &mut Body, input: MoveInput, params: &MoveParams, world: &World) {
    let cap = capsule();
    let dt = SIM_DT;

    // A body that ended up inside geometry (spawned there, or the world moved)
    // is pushed out before it moves.
    for _ in 0..4 {
        let push = world.depenetration(&cap, body.center());
        if push == Vec3::ZERO {
            break;
        }
        body.pos += push + push.normalize_or_zero() * SKIN;
    }

    let surface = world.water_surface_at(body.pos.x, body.pos.z);
    body.swimming = !body.mounted
        && surface.is_some_and(|s| {
            body.pos.y < s - SWIM_FLOAT_DEPTH + SWIM_ENTER_BAND && body.pos.y > s - SWIM_MAX_DEPTH
        });

    let grounded = body.on_floor || body.mounted || body.swimming;
    body.air_ticks = if grounded {
        0
    } else {
        body.air_ticks.saturating_add(1)
    };
    body.steep_ticks = body.steep_ticks.saturating_sub(1);
    let on_steep = body.steep_ticks > 0 && !body.on_floor && !body.mounted && !body.swimming;

    let jump_held = params.can_jump && input.held(MoveInput::JUMP);
    let jump_edge = jump_held && !body.prev_jump;
    body.prev_jump = jump_held;

    // Vertical.
    if let (true, Some(surface)) = (body.swimming, surface) {
        body.jump_buffer = 0;
        let mut target = surface - SWIM_FLOAT_DEPTH;
        if jump_held {
            target += SWIM_PADDLE_LIFT;
        }
        body.vel.y = move_toward(body.vel.y, (target - body.pos.y) * 4.0, GRAVITY * 0.6 * dt)
            .clamp(-3.0, 3.0);
    } else if body.mounted {
        body.jump_buffer = 0;
        let mut vertical = 0.0;
        if params.can_steer {
            vertical = f32::from(u8::from(jump_held))
                - f32::from(u8::from(input.held(MoveInput::DESCEND)));
        }
        if vertical >= 0.0
            && let Some(ground) = world.ray_down(body.pos, HOVER_PROBE)
        {
            let clearance = body.pos.y - ground.point.y;
            vertical = vertical
                .max(((HOVER_CLEARANCE - clearance) * HOVER_GAIN).clamp(0.0, HOVER_MAX_LIFT));
        }
        if body.pos.y > flight_ceiling(world, body.pos) {
            vertical = vertical.min(-0.5);
        }
        body.vel.y = move_toward(
            body.vel.y,
            vertical * MOUNTED_VERTICAL_SPEED,
            dt * MOUNTED_VERTICAL_ACCEL,
        );
    } else {
        if !body.on_floor {
            body.vel.y -= GRAVITY * dt;
        }
        if jump_ready(body, jump_edge) {
            body.vel.y = JUMP_VELOCITY;
        }
    }

    // Horizontal.
    let direction = if params.can_steer {
        input.direction()
    } else {
        Vec3::ZERO
    };
    let speed = if body.mounted {
        params.mounted_speed
    } else if body.swimming {
        params.swim_speed
    } else {
        params.walk_speed
    };
    if direction != Vec3::ZERO {
        let accel = if body.mounted {
            MOUNTED_ACCEL
        } else if body.swimming {
            SWIM_ACCEL
        } else {
            GROUND_ACCEL
        };
        body.vel.x = move_toward(body.vel.x, direction.x * speed, accel * dt);
        body.vel.z = move_toward(body.vel.z, direction.z * speed, accel * dt);
    } else {
        let decel = if body.mounted || !body.on_floor {
            speed * COAST_DECEL_FACTOR
        } else {
            GROUND_STOP_DECEL
        };
        body.vel.x = move_toward(body.vel.x, 0.0, decel * dt);
        body.vel.z = move_toward(body.vel.z, 0.0, decel * dt);
    }

    if on_steep {
        steep_slide(body);
    } else {
        body.slide_speed = 0.0;
    }
    step_up(body, world, &cap);

    let shove = body.shove;
    body.vel.x += shove.x;
    body.vel.z += shove.z;
    move_and_slide(body, world, &cap);
    body.vel.x -= shove.x;
    body.vel.z -= shove.z;
    let shove_len = shove.length();
    body.shove = if shove_len <= SHOVE_DECAY * dt {
        Vec3::ZERO
    } else {
        shove * ((shove_len - SHOVE_DECAY * dt) / shove_len)
    };

    remember_steep_ground(body, world);
    body.snap();
}

/// Jump with a press buffer and coyote time, so a press a moment early or a
/// moment after leaving an edge still jumps.
fn jump_ready(body: &mut Body, edge: bool) -> bool {
    if edge {
        body.jump_buffer = JUMP_BUFFER_TICKS;
    } else {
        body.jump_buffer = body.jump_buffer.saturating_sub(1);
    }
    if body.jump_buffer == 0 || body.vel.y > 1.0 {
        return false;
    }
    if !body.on_floor && body.air_ticks > COYOTE_TICKS {
        return false;
    }
    body.jump_buffer = 0;
    true
}

fn flight_ceiling(world: &World, pos: Vec3) -> f32 {
    world
        .ground_height(pos.x, pos.z)
        .map_or(world.flight_ceiling_y, |ground| {
            (ground + world.flight_max_above_ground).min(world.flight_ceiling_y)
        })
}

/// Too-steep ground: no pushing into the bank, and a slide down its fall line
/// that builds speed.
fn steep_slide(body: &mut Body) {
    let n = body.steep_normal;
    let across = Vec3::new(n.x, 0.0, n.z).normalize_or_zero();
    if across == Vec3::ZERO {
        return;
    }
    let mut planar = Vec3::new(body.vel.x, 0.0, body.vel.z);
    let into = planar.dot(across);
    if into < 0.0 {
        planar -= across * into;
    }
    let down = Vec3::new(0.0, -1.0, 0.0);
    let downhill = (down - n * n.dot(down)).normalize_or_zero();
    body.slide_speed = (body.slide_speed + STEEP_SLIDE_ACCEL * SIM_DT).min(STEEP_SLIDE_MAX);
    body.vel = planar + downhill * body.slide_speed;
}

/// Walks up a ledge (a tread, a doorstep, a sill) instead of stopping against
/// it: when the way ahead is blocked by something that is not walkable ground,
/// there is room one step up, and walkable ground to land on, lift the body.
fn step_up(body: &mut Body, world: &World, cap: &Capsule) {
    if !body.on_floor || body.mounted || body.swimming {
        return;
    }
    let planar = Vec3::new(body.vel.x, 0.0, body.vel.z);
    let speed = planar.length();
    if speed < STEP_UP_MIN_SPEED {
        return;
    }
    let probe = planar * (STEP_UP_PROBE / speed);
    let center = body.center();
    let Some(block) = world.sweep(cap, center, probe) else {
        return;
    };
    if is_floor_contact(world, center + probe * block.fraction, &block) {
        return;
    }
    let up = Vec3::new(0.0, STEP_UP_HEIGHT, 0.0);
    if world.sweep(cap, center, up).is_some() || world.sweep(cap, center + up, probe).is_some() {
        return;
    }
    let landing = body.pos + up + probe + Vec3::new(0.0, 0.05, 0.0);
    let Some(ground) = world.ray_down(landing, STEP_UP_HEIGHT + 0.35) else {
        return;
    };
    let rise = ground.point.y - body.pos.y;
    if rise <= 0.03 || rise > STEP_UP_HEIGHT || ground.normal.y < FLOOR_MIN_NORMAL_Y {
        return;
    }
    body.pos.y += rise + 0.02;
}

/// Sweeps the capsule along its velocity, sliding along whatever it hits, then
/// keeps a walking body on the ground going down slopes and steps.
fn move_and_slide(body: &mut Body, world: &World, cap: &Capsule) {
    let was_on_floor = body.on_floor;
    body.on_floor = false;
    let mut remaining = body.vel * SIM_DT;
    for _ in 0..MAX_SLIDES {
        if remaining.length_squared() < 1.0e-10 {
            break;
        }
        let Some(hit) = world.sweep(cap, body.center(), remaining) else {
            body.pos += remaining;
            break;
        };
        let n = hit.normal;
        let floor = is_floor_contact(world, body.center() + remaining * hit.fraction, &hit);
        body.pos += remaining * hit.fraction + n * SKIN;
        remaining *= 1.0 - hit.fraction;
        if floor {
            body.on_floor = true;
            remaining -= n * remaining.dot(n);
            if body.vel.y < 0.0 {
                body.vel.y = 0.0;
            }
        } else {
            if n.y > 0.2 && !body.mounted && !body.swimming {
                body.steep_normal = n;
                body.steep_ticks = STEEP_MEMORY_TICKS;
            }
            if n.y < -0.3 && body.vel.y > 0.0 {
                body.vel.y = 0.0;
            }
            // A body standing on ground treats walls and banks as vertical: it
            // never climbs one by sliding up its slanted face, and never gets
            // bounced off the foot of a bank it is pressed against. Airborne, it
            // slides along the real surface.
            let supported = was_on_floor || body.on_floor;
            let wall = if supported {
                Vec3::new(n.x, 0.0, n.z).normalize_or_zero()
            } else {
                n
            };
            remaining -= wall * remaining.dot(wall);
            let into = body.vel.dot(wall);
            if into < 0.0 {
                body.vel -= wall * into;
            }
        }
    }

    let jumping = body.vel.y > 0.0;
    if !body.on_floor && was_on_floor && !jumping && !body.mounted && !body.swimming {
        let snap_motion = Vec3::new(0.0, -FLOOR_SNAP_LENGTH, 0.0);
        if let Some(hit) = world.sweep(cap, body.center(), snap_motion)
            && is_floor_contact(world, body.center() + snap_motion * hit.fraction, &hit)
        {
            body.pos += snap_motion * hit.fraction + hit.normal * SKIN;
            body.on_floor = true;
            body.vel.y = 0.0;
        }
    }
}

/// Whether a contact holds the body up. A face whose normal is walkable does.
/// So does an edge or corner under the capsule's lower hemisphere (a stair
/// nosing, a kerb) when the surface just beyond it is walkable: the rounded
/// bottom meets such an edge at a slant, and judging it by that slanted contact
/// normal would make every tread a "steep slope" the body bounces off.
fn is_floor_contact(world: &World, center_at_contact: Vec3, hit: &SweepHit) -> bool {
    if hit.normal.y >= FLOOR_MIN_NORMAL_Y {
        return true;
    }
    if hit.normal.y <= 0.05 {
        return false;
    }
    let lower_sphere_y = center_at_contact.y - (CAPSULE_HEIGHT * 0.5 - CAPSULE_RADIUS);
    if hit.point.y > lower_sphere_y {
        return false;
    }
    let away = Vec3::new(
        hit.point.x - center_at_contact.x,
        0.0,
        hit.point.z - center_at_contact.z,
    )
    .normalize_or_zero();
    let probe = hit.point + away * 0.02 + Vec3::new(0.0, 0.05, 0.0);
    world
        .ray_down(probe, 0.1)
        .is_some_and(|ground| ground.normal.y >= FLOOR_MIN_NORMAL_Y)
}

/// Sliding along a bank often reports no contact for a tick; while the steep
/// ground is still under the feet, keep the slide going.
fn remember_steep_ground(body: &mut Body, world: &World) {
    if body.on_floor || body.mounted || body.swimming || body.steep_ticks == 0 {
        return;
    }
    if let Some(below) = world.ray_down(body.pos + Vec3::new(0.0, 0.05, 0.0), 1.1)
        && below.normal.y > 0.2
        && below.normal.y < FLOOR_MIN_NORMAL_Y
    {
        body.steep_normal = below.normal;
        body.steep_ticks = STEEP_MEMORY_TICKS;
    }
}
