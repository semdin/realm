//! Wire protocol. Client and server are built from the same commit, so the
//! version only guards against an old installed client talking to a new
//! server; it never has to be bumped by hand for drift between repositories.
//!
//! Inputs travel as unreliable datagrams with the last few repeated, so one
//! lost packet loses nothing. Snapshots travel as unreliable datagrams too:
//! the owner's body goes whole and lossless (the client rewinds to it exactly),
//! every other entity goes as a delta against a snapshot the client has
//! acknowledged.

pub mod bits;

use std::collections::BTreeMap;

use realm_sim::input::MoveInput;
use realm_sim::movement::Body;
use realm_sim::{Vec3, WIRE_GRID};

use bits::{BitReader, BitWriter, DecodeError};

/// Bumped whenever a message layout changes.
pub const PROTOCOL_VERSION: u16 = 1;

/// QUIC application protocol name, checked during the TLS handshake.
pub const ALPN: &[u8] = b"realm/1";

/// Inputs repeated in every input packet.
pub const MAX_INPUTS_PER_PACKET: usize = 8;

const KIND_INPUTS: u32 = 1;
const KIND_SNAPSHOT: u32 = 2;
const KIND_BITS: u32 = 4;

/// Client -> server, every tick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputBatch {
    /// Sequence number of the last input in `inputs`.
    pub newest_seq: u32,
    /// Newest snapshot tick the client has received (its delta baseline).
    pub ack_snapshot: u32,
    /// Oldest first, at most [`MAX_INPUTS_PER_PACKET`].
    pub inputs: Vec<MoveInput>,
}

/// Another entity as the client sees it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EntityState {
    /// Feet position, on the wire grid.
    pub pos: Vec3,
    pub yaw: u16,
    /// Animation / pose code.
    pub state: u8,
}

/// Server -> client.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub tick: u32,
    /// Tick of the snapshot the entity deltas are against (0 = none, full).
    pub baseline_tick: u32,
    /// Last input sequence the server applied to the owner's body.
    pub last_input_seq: u32,
    /// The owner's body after that input.
    pub own: Body,
    /// Every entity in the client's interest set, by id.
    pub entities: BTreeMap<u32, EntityState>,
}

pub fn encode_inputs(batch: &InputBatch) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.bits(KIND_INPUTS, KIND_BITS);
    w.u32(batch.newest_seq);
    w.u32(batch.ack_snapshot);
    let count = batch.inputs.len().min(MAX_INPUTS_PER_PACKET);
    w.bits(count as u32, 4);
    for input in &batch.inputs[batch.inputs.len() - count..] {
        w.u8(input.strafe as u8);
        w.u8(input.forward as u8);
        w.u16(input.yaw);
        w.bits(u32::from(input.buttons), 2);
    }
    w.finish()
}

pub fn decode_inputs(bytes: &[u8]) -> Result<InputBatch, DecodeError> {
    let mut r = BitReader::new(bytes);
    if r.bits(KIND_BITS)? != KIND_INPUTS {
        return Err(DecodeError("not an input packet"));
    }
    let newest_seq = r.u32()?;
    let ack_snapshot = r.u32()?;
    let count = r.bits(4)? as usize;
    if count == 0 || count > MAX_INPUTS_PER_PACKET {
        return Err(DecodeError("input count"));
    }
    let mut inputs = Vec::with_capacity(count);
    for _ in 0..count {
        inputs.push(MoveInput {
            strafe: r.u8()? as i8,
            forward: r.u8()? as i8,
            yaw: r.u16()?,
            buttons: r.bits(2)? as u8,
        });
    }
    r.end()?;
    Ok(InputBatch {
        newest_seq,
        ack_snapshot,
        inputs,
    })
}

/// Encodes `snapshot`, delta-coding entities against `baseline` (the entity
/// set of snapshot `snapshot.baseline_tick`, which the client acknowledged).
pub fn encode_snapshot(
    snapshot: &Snapshot,
    baseline: Option<&BTreeMap<u32, EntityState>>,
) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.bits(KIND_SNAPSHOT, KIND_BITS);
    w.u32(snapshot.tick);
    let baseline = if snapshot.baseline_tick == 0 {
        None
    } else {
        baseline
    };
    w.u32(if baseline.is_some() {
        snapshot.baseline_tick
    } else {
        0
    });
    w.u32(snapshot.last_input_seq);
    write_body(&mut w, &snapshot.own);

    let empty = BTreeMap::new();
    let base = baseline.unwrap_or(&empty);
    let removed: Vec<u32> = base
        .keys()
        .filter(|id| !snapshot.entities.contains_key(id))
        .copied()
        .collect();
    w.unsigned(removed.len() as u32);
    let mut prev = 0_u32;
    for id in removed {
        w.unsigned(id - prev);
        prev = id;
    }
    // Entities whose state is the same as in the baseline are not sent.
    let changed: Vec<(&u32, &EntityState)> = snapshot
        .entities
        .iter()
        .filter(|(id, state)| base.get(id) != Some(state))
        .collect();
    w.unsigned(changed.len() as u32);
    let mut prev = 0_u32;
    for (&id, state) in changed {
        w.unsigned(id - prev);
        prev = id;
        match base.get(&id) {
            Some(old) => {
                w.bool(true);
                let (a, b) = (grid(state.pos), grid(old.pos));
                let moved = a != b;
                w.bool(moved);
                if moved {
                    // Per axis: a zero bit, or a one bit and the delta. A body
                    // walking on level ground pays one bit for its height.
                    for i in 0..3 {
                        let delta = a[i].wrapping_sub(b[i]);
                        w.bool(delta != 0);
                        if delta != 0 {
                            w.signed(delta);
                        }
                    }
                }
                w.bool(state.yaw != old.yaw);
                if state.yaw != old.yaw {
                    // Turning is gradual: send the shortest signed turn.
                    w.signed(i32::from(state.yaw.wrapping_sub(old.yaw) as i16));
                }
                w.bool(state.state != old.state);
                if state.state != old.state {
                    w.u8(state.state);
                }
            }
            None => {
                w.bool(false);
                for c in grid(state.pos) {
                    w.signed(c);
                }
                w.u16(state.yaw);
                w.u8(state.state);
            }
        }
    }
    w.finish()
}

/// Decodes a snapshot. `baseline` must be the entity set of the snapshot the
/// packet names as its baseline (the caller looks it up by tick).
pub fn decode_snapshot(
    bytes: &[u8],
    baseline: impl FnOnce(u32) -> Option<BTreeMap<u32, EntityState>>,
) -> Result<Snapshot, DecodeError> {
    let mut r = BitReader::new(bytes);
    if r.bits(KIND_BITS)? != KIND_SNAPSHOT {
        return Err(DecodeError("not a snapshot"));
    }
    let tick = r.u32()?;
    let baseline_tick = r.u32()?;
    let last_input_seq = r.u32()?;
    let own = read_body(&mut r)?;
    let mut entities = if baseline_tick == 0 {
        BTreeMap::new()
    } else {
        baseline(baseline_tick).ok_or(DecodeError("unknown baseline"))?
    };
    let removed = r.unsigned()?;
    let mut id = 0_u32;
    for _ in 0..removed {
        id = id
            .checked_add(r.unsigned()?)
            .ok_or(DecodeError("entity id overflow"))?;
        entities.remove(&id);
    }
    let changed = r.unsigned()?;
    let mut id = 0_u32;
    for _ in 0..changed {
        id = id
            .checked_add(r.unsigned()?)
            .ok_or(DecodeError("entity id overflow"))?;
        let state = if r.bool()? {
            let old = *entities
                .get(&id)
                .ok_or(DecodeError("delta for an entity the baseline lacks"))?;
            let mut pos = grid(old.pos);
            if r.bool()? {
                for c in &mut pos {
                    if r.bool()? {
                        *c = c.wrapping_add(r.signed()?);
                    }
                }
            }
            let yaw = if r.bool()? {
                old.yaw.wrapping_add(r.signed()? as i16 as u16)
            } else {
                old.yaw
            };
            let state = if r.bool()? { r.u8()? } else { old.state };
            EntityState {
                pos: from_grid(pos),
                yaw,
                state,
            }
        } else {
            let pos = [r.signed()?, r.signed()?, r.signed()?];
            EntityState {
                pos: from_grid(pos),
                yaw: r.u16()?,
                state: r.u8()?,
            }
        };
        entities.insert(id, state);
    }
    r.end()?;
    Ok(Snapshot {
        tick,
        baseline_tick,
        last_input_seq,
        own,
        entities,
    })
}

fn grid_value(v: f32) -> i32 {
    // The simulation keeps every value on the grid, so this is exact.
    (v * WIRE_GRID) as i32
}

fn grid(v: Vec3) -> [i32; 3] {
    [grid_value(v.x), grid_value(v.y), grid_value(v.z)]
}

fn from_grid(v: [i32; 3]) -> Vec3 {
    Vec3::new(
        v[0] as f32 / WIRE_GRID,
        v[1] as f32 / WIRE_GRID,
        v[2] as f32 / WIRE_GRID,
    )
}

fn write_vec(w: &mut BitWriter, v: Vec3) {
    for c in grid(v) {
        w.signed(c);
    }
}

fn read_vec(r: &mut BitReader<'_>) -> Result<Vec3, DecodeError> {
    Ok(from_grid([r.signed()?, r.signed()?, r.signed()?]))
}

/// The owner's body, lossless: every float is on the wire grid already.
fn write_body(w: &mut BitWriter, b: &Body) {
    write_vec(w, b.pos);
    write_vec(w, b.vel);
    write_vec(w, b.shove);
    write_vec(w, b.steep_normal);
    w.signed(grid_value(b.slide_speed));
    w.bool(b.on_floor);
    w.bool(b.mounted);
    w.bool(b.swimming);
    w.bool(b.prev_jump);
    w.u16(b.air_ticks);
    w.u8(b.jump_buffer);
    w.u8(b.steep_ticks);
}

fn read_body(r: &mut BitReader<'_>) -> Result<Body, DecodeError> {
    Ok(Body {
        pos: read_vec(r)?,
        vel: read_vec(r)?,
        shove: read_vec(r)?,
        steep_normal: read_vec(r)?,
        slide_speed: r.signed()? as f32 / WIRE_GRID,
        on_floor: r.bool()?,
        mounted: r.bool()?,
        swimming: r.bool()?,
        prev_jump: r.bool()?,
        air_ticks: r.u16()?,
        jump_buffer: r.u8()?,
        steep_ticks: r.u8()?,
    })
}
