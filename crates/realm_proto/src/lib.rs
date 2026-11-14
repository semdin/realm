//! Wire protocol. Client and server are built from the same commit, so the
//! version only guards against an old installed client talking to a new
//! server; it never has to be bumped by hand for drift between repositories.
//!
//! Joining goes over one reliable QUIC stream: the client sends [`Hello`]
//! (protocol version and a signed login ticket), the server answers with
//! [`JoinReply`]. The stream then stays open as the control channel: framed
//! [`control`] messages both ways (the character sheet, requests and their
//! results), reliable and in order. Inputs travel as unreliable datagrams with the
//! last few repeated, so one lost packet loses nothing, and snapshots travel as
//! unreliable datagrams too: the owner's body whole and lossless (the client
//! rewinds to it exactly), every other entity as a delta against a snapshot
//! the client has acknowledged.

pub mod bits;
pub mod control;
pub mod coord;
pub mod ticket;

use realm_sim::input::MoveInput;
use realm_sim::movement::{Body, Restraint};
use realm_sim::{Vec3, WIRE_GRID};

use bits::{BitReader, BitWriter, DecodeError};

pub use ed25519_dalek::{SigningKey, VerifyingKey};

/// Bumped whenever a message layout changes.
pub const PROTOCOL_VERSION: u16 = 15;

/// QUIC application protocol name, checked during the TLS handshake.
pub const ALPN: &[u8] = b"realm/15";

/// Inputs repeated in every input packet.
pub const MAX_INPUTS_PER_PACKET: usize = 8;

/// Largest datagram any side sends. QUIC over a 1280-byte IPv6 minimum MTU
/// leaves room for about 1200 bytes of payload on every path.
pub const MAX_DATAGRAM: usize = 1200;

const KIND_INPUTS: u32 = 1;
const KIND_SNAPSHOT: u32 = 2;
const KIND_HELLO: u32 = 3;
const KIND_JOIN: u32 = 4;
const KIND_BITS: u32 = 4;

/// Client -> server, first message on the join stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hello {
    pub protocol: u16,
    pub ticket: Vec<u8>,
}

/// Server -> client, the answer on the join stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JoinReply {
    Accepted {
        /// The joining player's entity id.
        entity: u32,
        tick: u32,
        /// SHA-256 of the server's content; the client refuses to play on
        /// different data.
        content_hash: [u8; 32],
    },
    Refused(String),
}

/// One tick of player intent: movement plus at most one action.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct InputFrame {
    /// The simulation tick the client ran this input on. The server runs it
    /// with the world as it was on that tick (staircase poses), so arrival
    /// time never changes the result.
    pub tick: u32,
    pub movement: MoveInput,
    /// 0 = none, otherwise a cast: the spell's index + 1 (4 bits).
    pub action: u8,
    /// Entity the action is aimed at (0 = none).
    pub target: u32,
    /// Where the action is aimed, in 1/16 m (only sent with an action).
    pub aim: [i32; 3],
}

/// Aim points travel in steps of 1/16 m.
pub const AIM_GRID: f32 = 16.0;

impl InputFrame {
    /// `point` as the frame's aim.
    #[must_use]
    pub fn aimed_at(mut self, point: Vec3) -> Self {
        let q = |v: f32| (v * AIM_GRID).round() as i32;
        self.aim = [q(point.x), q(point.y), q(point.z)];
        self
    }

    #[must_use]
    pub fn aim_point(&self) -> Vec3 {
        Vec3::new(
            self.aim[0] as f32 / AIM_GRID,
            self.aim[1] as f32 / AIM_GRID,
            self.aim[2] as f32 / AIM_GRID,
        )
    }
}

/// Client -> server, every tick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputBatch {
    /// Sequence number of the last input in `inputs`.
    pub newest_seq: u32,
    /// Newest snapshot tick the client has received (its delta baseline).
    pub ack_snapshot: u32,
    /// Oldest first, at most [`MAX_INPUTS_PER_PACKET`].
    pub inputs: Vec<InputFrame>,
}

/// Another entity as the client sees it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EntityState {
    /// Feet position, on the wire grid.
    pub pos: Vec3,
    pub yaw: u16,
    /// Animation / pose code.
    pub state: u8,
    /// What it is: 0 = player, 1.. = creature species (content order).
    /// Fixed for the life of an entity id.
    pub kind: u16,
    /// Health as a fraction of 255.
    pub hp: u8,
    /// Crowd control and damage over time on the body (STATUS_* bits).
    pub status: u8,
}

/// Status bits (`EntityState::status`).
pub const STATUS_STUN: u8 = 1 << 0;
pub const STATUS_FREEZE: u8 = 1 << 1;
pub const STATUS_SLOW: u8 = 1 << 2;
pub const STATUS_BLEED: u8 = 1 << 3;
pub const STATUS_BURN: u8 = 1 << 4;
pub const STATUS_POISON: u8 = 1 << 5;
pub const STATUS_KNOCKED: u8 = 1 << 6;
pub const STATUS_WEAK: u8 = 1 << 7;
/// A body that cannot act while any of these runs.
pub const STATUS_LOCKED: u8 = STATUS_STUN | STATUS_FREEZE | STATUS_KNOCKED;

/// `EntityState::kind` of a creature: its species + 1 in the low bits, and
/// these marks over them.
pub const KIND_ELITE: u16 = 0x8000;
pub const KIND_ENRAGED: u16 = 0x4000;
pub const KIND_BOSS: u16 = 0x2000;
pub const KIND_SPECIES: u16 = 0x1FFF;
/// A loot chest's kind (no species bits); KIND_CHEST_RARE when a piece in
/// it carries enchantment bonuses.
pub const KIND_CHEST: u16 = 0x1000;
pub const KIND_CHEST_RARE: u16 = 0x1001;

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
    /// The owner's health, 0..=255.
    pub own_hp: u8,
    /// The owner's health, maximum health, mana, maximum mana (the bars).
    pub own_vitals: [u32; 4],
    /// What the server holds the owner's body to (stunned, thrown, webbed),
    /// so a replay applies it to the same inputs.
    pub own_restraint: Restraint,
    /// STATUS_* bits on the owner (what the others see on it).
    pub own_status: u8,
    /// Counts the owner's deaths and respawns (wrapping): a change means
    /// the server moved the body, even when two of them fell between the
    /// snapshots the client got (a respawn and an instant death).
    pub own_life: u8,
    /// Every entity in the client's interest set, sorted by id.
    pub entities: EntitySet,
}

/// Entities sorted by id, ascending. Snapshots, baselines and the client's
/// view are all in this form so encoding and decoding are linear merges.
pub type EntitySet = Vec<(u32, EntityState)>;

pub fn encode_hello(hello: &Hello) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.bits(KIND_HELLO, KIND_BITS);
    w.u16(hello.protocol);
    w.unsigned(hello.ticket.len() as u32);
    for b in &hello.ticket {
        w.u8(*b);
    }
    w.finish()
}

pub fn decode_hello(bytes: &[u8]) -> Result<Hello, DecodeError> {
    let mut r = BitReader::new(bytes);
    if r.bits(KIND_BITS)? != KIND_HELLO {
        return Err(DecodeError("not a hello"));
    }
    let protocol = r.u16()?;
    let len = r.unsigned()? as usize;
    if len > 512 {
        return Err(DecodeError("ticket too long"));
    }
    let ticket = (0..len).map(|_| r.u8()).collect::<Result<Vec<_>, _>>()?;
    r.end()?;
    Ok(Hello { protocol, ticket })
}

pub fn encode_join_reply(reply: &JoinReply) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.bits(KIND_JOIN, KIND_BITS);
    match reply {
        JoinReply::Accepted {
            entity,
            tick,
            content_hash,
        } => {
            w.bool(true);
            w.u32(*entity);
            w.u32(*tick);
            for b in content_hash {
                w.u8(*b);
            }
        }
        JoinReply::Refused(reason) => {
            w.bool(false);
            let bytes = reason.as_bytes();
            let len = bytes.len().min(255);
            w.u8(len as u8);
            for b in &bytes[..len] {
                w.u8(*b);
            }
        }
    }
    w.finish()
}

pub fn decode_join_reply(bytes: &[u8]) -> Result<JoinReply, DecodeError> {
    let mut r = BitReader::new(bytes);
    if r.bits(KIND_BITS)? != KIND_JOIN {
        return Err(DecodeError("not a join reply"));
    }
    let reply = if r.bool()? {
        let entity = r.u32()?;
        let tick = r.u32()?;
        let mut content_hash = [0_u8; 32];
        for b in &mut content_hash {
            *b = r.u8()?;
        }
        JoinReply::Accepted {
            entity,
            tick,
            content_hash,
        }
    } else {
        let len = usize::from(r.u8()?);
        let bytes = (0..len).map(|_| r.u8()).collect::<Result<Vec<_>, _>>()?;
        JoinReply::Refused(String::from_utf8_lossy(&bytes).into_owned())
    };
    r.end()?;
    Ok(reply)
}

pub fn encode_inputs(batch: &InputBatch) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.bits(KIND_INPUTS, KIND_BITS);
    w.u32(batch.newest_seq);
    w.u32(batch.ack_snapshot);
    let count = batch.inputs.len().min(MAX_INPUTS_PER_PACKET);
    w.bits(count as u32, 4);
    let frames = &batch.inputs[batch.inputs.len() - count..];
    let newest_tick = frames.last().map_or(0, |f| f.tick);
    w.u32(newest_tick);
    for frame in frames {
        w.unsigned(newest_tick.wrapping_sub(frame.tick));
        let m = frame.movement;
        w.u8(m.strafe as u8);
        w.u8(m.forward as u8);
        w.u16(m.yaw);
        w.bits(u32::from(m.buttons), 2);
        w.bits(u32::from(frame.action), 4);
        if frame.action != 0 {
            w.unsigned(frame.target);
            for v in frame.aim {
                w.signed(v);
            }
        }
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
    let newest_tick = r.u32()?;
    let mut inputs = Vec::with_capacity(count);
    for _ in 0..count {
        let tick = newest_tick.wrapping_sub(r.unsigned()?);
        let movement = MoveInput {
            strafe: r.u8()? as i8,
            forward: r.u8()? as i8,
            yaw: r.u16()?,
            buttons: r.bits(2)? as u8,
        };
        let action = r.bits(4)? as u8;
        let (target, aim) = if action != 0 {
            (r.unsigned()?, [r.signed()?, r.signed()?, r.signed()?])
        } else {
            (0, [0; 3])
        };
        inputs.push(InputFrame {
            tick,
            movement,
            action,
            target,
            aim,
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
/// Entities whose state equals the baseline's are not sent at all, so a
/// server that leaves an entity at its baseline state skips it this time.
/// Both sets must be sorted by id.
pub fn encode_snapshot(snapshot: &Snapshot, baseline: Option<&[(u32, EntityState)]>) -> Vec<u8> {
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
    w.u8(snapshot.own_hp);
    for v in snapshot.own_vitals {
        w.unsigned(v);
    }
    let r = snapshot.own_restraint;
    w.bool(r != Restraint::default());
    if r != Restraint::default() {
        for v in [r.lock_from, r.lock_until, r.web_from, r.web_until] {
            w.unsigned(v);
        }
        w.u8(r.web_pct);
    }
    w.u8(snapshot.own_status);
    w.u8(snapshot.own_life);

    let base = baseline.unwrap_or(&[]);
    let next = &snapshot.entities;
    debug_assert!(
        next.windows(2).all(|p| p[0].0 < p[1].0),
        "snapshot entities sorted by id"
    );
    let mut removed: Vec<u32> = Vec::new();
    let mut changed: Vec<(u32, &EntityState, Option<&EntityState>)> = Vec::new();
    let (mut i, mut j) = (0, 0);
    loop {
        match (base.get(i), next.get(j)) {
            (Some(b), Some(n)) if b.0 == n.0 => {
                if b.1 != n.1 {
                    changed.push((n.0, &n.1, Some(&b.1)));
                }
                i += 1;
                j += 1;
            }
            (Some(b), Some(n)) if b.0 < n.0 => {
                removed.push(b.0);
                i += 1;
            }
            (Some(b), None) => {
                removed.push(b.0);
                i += 1;
            }
            (_, Some(n)) => {
                changed.push((n.0, &n.1, None));
                j += 1;
            }
            (None, None) => break,
        }
    }
    w.unsigned(removed.len() as u32);
    let mut prev = 0_u32;
    for id in removed {
        w.unsigned(id - prev);
        prev = id;
    }
    w.unsigned(changed.len() as u32);
    let mut prev = 0_u32;
    for (id, state, old) in changed {
        w.unsigned(id - prev);
        prev = id;
        match old {
            Some(old) => {
                w.bool(true);
                let (a, b) = (grid(state.pos), grid(old.pos));
                let moved = a != b;
                w.bool(moved);
                if moved {
                    // Per axis: a zero bit, or a one bit and the delta. A body
                    // walking on level ground pays one bit for its height.
                    for k in 0..3 {
                        let delta = a[k].wrapping_sub(b[k]);
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
                w.bool(state.hp != old.hp);
                if state.hp != old.hp {
                    w.u8(state.hp);
                }
                w.bool(state.status != old.status);
                if state.status != old.status {
                    w.u8(state.status);
                }
            }
            None => {
                w.bool(false);
                for c in grid(state.pos) {
                    w.signed(c);
                }
                w.u16(state.yaw);
                w.u8(state.state);
                w.unsigned(u32::from(state.kind));
                w.u8(state.hp);
                w.u8(state.status);
            }
        }
    }
    w.finish()
}

/// Decodes a snapshot. `baseline` must return the entity set of the snapshot
/// the packet names as its baseline (the caller looks it up by tick).
pub fn decode_snapshot<'a>(
    bytes: &[u8],
    baseline: impl FnOnce(u32) -> Option<&'a [(u32, EntityState)]>,
) -> Result<Snapshot, DecodeError> {
    let mut r = BitReader::new(bytes);
    if r.bits(KIND_BITS)? != KIND_SNAPSHOT {
        return Err(DecodeError("not a snapshot"));
    }
    let tick = r.u32()?;
    let baseline_tick = r.u32()?;
    let last_input_seq = r.u32()?;
    let own = read_body(&mut r)?;
    let own_hp = r.u8()?;
    let own_vitals = [r.unsigned()?, r.unsigned()?, r.unsigned()?, r.unsigned()?];
    let own_restraint = if r.bool()? {
        Restraint {
            lock_from: r.unsigned()?,
            lock_until: r.unsigned()?,
            web_from: r.unsigned()?,
            web_until: r.unsigned()?,
            web_pct: r.u8()?,
        }
    } else {
        Restraint::default()
    };
    let own_status = r.u8()?;
    let own_life = r.u8()?;
    let base: &[(u32, EntityState)] = if baseline_tick == 0 {
        &[]
    } else {
        baseline(baseline_tick).ok_or(DecodeError("unknown baseline"))?
    };
    let find = |id: u32| {
        base.binary_search_by_key(&id, |e| e.0)
            .ok()
            .map(|i| base[i].1)
    };

    let removed_count = r.unsigned()? as usize;
    if removed_count > base.len() {
        return Err(DecodeError("more removals than baseline entities"));
    }
    let mut removed = Vec::with_capacity(removed_count);
    let mut id = 0_u32;
    for k in 0..removed_count {
        let step = r.unsigned()?;
        if k > 0 && step == 0 {
            return Err(DecodeError("entity ids not ascending"));
        }
        id = id
            .checked_add(step)
            .ok_or(DecodeError("entity id overflow"))?;
        removed.push(id);
    }
    let changed_count = r.unsigned()? as usize;
    if changed_count > 4096 {
        return Err(DecodeError("too many entities"));
    }
    let mut changed: EntitySet = Vec::with_capacity(changed_count);
    let mut id = 0_u32;
    for k in 0..changed_count {
        let step = r.unsigned()?;
        if k > 0 && step == 0 {
            return Err(DecodeError("entity ids not ascending"));
        }
        id = id
            .checked_add(step)
            .ok_or(DecodeError("entity id overflow"))?;
        let state = if r.bool()? {
            let old = find(id).ok_or(DecodeError("delta for an entity the baseline lacks"))?;
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
            let hp = if r.bool()? { r.u8()? } else { old.hp };
            let status = if r.bool()? { r.u8()? } else { old.status };
            EntityState {
                pos: from_grid(pos),
                yaw,
                state,
                kind: old.kind,
                hp,
                status,
            }
        } else {
            let pos = [r.signed()?, r.signed()?, r.signed()?];
            let yaw = r.u16()?;
            let state = r.u8()?;
            let kind = u16::try_from(r.unsigned()?).map_err(|_| DecodeError("entity kind"))?;
            EntityState {
                pos: from_grid(pos),
                yaw,
                state,
                kind,
                hp: r.u8()?,
                status: r.u8()?,
            }
        };
        changed.push((id, state));
    }
    r.end()?;

    // Merge: the baseline without removed or changed ids, plus the changed.
    let mut entities: EntitySet = Vec::with_capacity(base.len() + changed.len());
    let (mut i, mut j, mut k) = (0, 0, 0);
    while i < base.len() || k < changed.len() {
        match (base.get(i).map(|e| e.0), changed.get(k).map(|e| e.0)) {
            (Some(bid), Some(cid)) if cid <= bid => {
                entities.push(changed[k]);
                k += 1;
                if cid == bid {
                    i += 1;
                }
            }
            (Some(bid), _) => {
                while removed.get(j).is_some_and(|&rid| rid < bid) {
                    j += 1;
                }
                if removed.get(j) != Some(&bid) {
                    entities.push(base[i]);
                }
                i += 1;
            }
            (None, Some(_)) => {
                entities.push(changed[k]);
                k += 1;
            }
            (None, None) => break,
        }
    }
    Ok(Snapshot {
        tick,
        baseline_tick,
        last_input_seq,
        own,
        own_hp,
        own_vitals,
        own_restraint,
        own_status,
        own_life,
        entities,
    })
}

fn grid_value(v: f32) -> i32 {
    // Bodies keep every value on the grid, so this is exact for them; other
    // positions are rounded to it here.
    libm_round(v * WIRE_GRID) as i32
}

fn libm_round(v: f32) -> f32 {
    // Round half away from zero without platform libm.
    if v >= 0.0 {
        (v + 0.5).trunc()
    } else {
        (v - 0.5).trunc()
    }
}

/// Snaps a position to the wire grid (what the client will receive).
#[must_use]
pub fn on_grid(v: Vec3) -> Vec3 {
    from_grid(grid(v))
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
