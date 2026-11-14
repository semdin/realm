//! The client's simulation side, without any I/O: it predicts the player's
//! own body with the same rules the server runs, reconciles against the
//! server's body when a snapshot confirms an input, and keeps a short
//! history of snapshots to draw everyone else between two of them.
//!
//! Because the rules are deterministic and each input carries the tick it
//! was run on, the server's result for an input equals the prediction bit for
//! bit; a reconciliation that changes anything is a real disagreement (a
//! server-side effect such as a knock-back or a respawn), and is counted.

use std::collections::VecDeque;

use realm_proto::{EntitySet, EntityState, InputBatch, InputFrame, Snapshot};
use realm_sim::input::MoveInput;
use realm_sim::movement::{self, Body, MoveParams, Restraint};
use realm_sim::staircase::Staircases;
use realm_sim::world::World;
use realm_sim::{SIM_HZ, Vec3};

/// Inputs repeated in each input packet.
const REDUNDANCY: usize = 4;
/// Snapshot entity sets kept as delta baselines and for interpolation.
const KEEP_SNAPSHOTS: usize = 40;
/// Remote entities are drawn this many ticks behind the newest snapshot
/// (two snapshot intervals at 15 Hz plus margin).
pub const INTERPOLATION_TICKS: f64 = 5.0;

struct Predicted {
    seq: u32,
    frame: InputFrame,
    /// The predicted body after this input.
    after: Body,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ClientStats {
    pub snapshots: u64,
    pub decode_errors: u64,
    /// Reconciliations where the server's body differed from the prediction.
    pub corrections: u64,
    /// Largest such difference, metres.
    pub max_correction: f32,
    /// Inputs replayed after reconciliations.
    pub replayed: u64,
    /// Reconciliations the server caused on purpose: the body stopping at a
    /// death and moving to the respawn point. Not prediction errors.
    pub server_moves: u64,
}

/// A remote entity as it should be drawn now.
#[derive(Clone, Copy, Debug)]
pub struct RemoteEntity {
    pub id: u32,
    pub kind: u16,
    pub pos: Vec3,
    pub yaw: f32,
    pub state: u8,
    pub hp: u8,
    /// STATUS_* bits.
    pub status: u8,
}

pub struct ClientCore {
    world: World,
    stairs: Staircases,
    params: MoveParams,
    me: u32,
    /// Last simulated tick.
    tick: u32,
    seq: u32,
    body: Option<Body>,
    prev_pos: Vec3,
    history: VecDeque<Predicted>,
    sent: VecDeque<InputFrame>,
    snapshots: VecDeque<(u32, EntitySet)>,
    acked: u32,
    /// Newest input sequence a snapshot has confirmed.
    confirmed: u32,
    /// Server tick estimate as `local_ticks + offset` (see `server_tick_at`).
    clock_offset: Option<f64>,
    own_hp: u8,
    /// Health, maximum health, mana, maximum mana from the newest snapshot.
    own_vitals: [u32; 4],
    /// The newest snapshot said the player is dead: like the server, the
    /// body then ignores its inputs until the respawn.
    dead: bool,
    /// The newest snapshot's holds on the body (stunned, thrown, webbed),
    /// and its STATUS_* bits.
    restraint: Restraint,
    own_status: u8,
    /// The newest snapshot's death/respawn count.
    life: Option<u8>,
    pub stats: ClientStats,
}

impl ClientCore {
    /// `start_tick` is the server tick from the join reply (plus the time the
    /// reply took, in ticks, if known).
    #[must_use]
    pub fn new(world: World, stairs: Staircases, me: u32, start_tick: u32) -> Self {
        Self {
            world,
            stairs,
            params: MoveParams::default(),
            me,
            tick: start_tick,
            seq: 0,
            body: None,
            prev_pos: Vec3::ZERO,
            history: VecDeque::new(),
            sent: VecDeque::new(),
            snapshots: VecDeque::new(),
            acked: 0,
            confirmed: 0,
            clock_offset: None,
            own_hp: 255,
            own_vitals: [0; 4],
            dead: false,
            restraint: Restraint::default(),
            own_status: 0,
            life: None,
            stats: ClientStats::default(),
        }
    }

    #[must_use]
    pub fn me(&self) -> u32 {
        self.me
    }

    #[must_use]
    pub fn tick(&self) -> u32 {
        self.tick
    }

    #[must_use]
    pub fn world(&self) -> &World {
        &self.world
    }

    #[must_use]
    pub fn body(&self) -> Option<&Body> {
        self.body.as_ref()
    }

    #[must_use]
    pub fn own_vitals(&self) -> [u32; 4] {
        self.own_vitals
    }

    /// STATUS_* bits on the player's own body.
    #[must_use]
    pub fn own_status(&self) -> u8 {
        self.own_status
    }

    /// Whether the server holds the body still (stunned or thrown) at the
    /// newest predicted tick: no casts then.
    #[must_use]
    pub fn locked(&self) -> bool {
        self.restraint.locked(self.tick)
    }

    pub fn own_hp(&self) -> u8 {
        self.own_hp
    }

    /// The player's body drawn `alpha` of the way from the previous tick to
    /// the current one.
    #[must_use]
    pub fn own_draw_position(&self, alpha: f32) -> Option<Vec3> {
        self.body
            .map(|b| self.prev_pos + (b.pos - self.prev_pos) * alpha.clamp(0.0, 1.0))
    }

    fn simulate(
        world: &mut World,
        stairs: &mut Staircases,
        params: &MoveParams,
        restraint: &Restraint,
        body: &mut Body,
        frame: &InputFrame,
        dead: bool,
    ) {
        if dead {
            // The server consumes a dead player's inputs without moving it.
            return;
        }
        if !stairs.flights.is_empty() {
            stairs.apply(world, frame.tick);
        }
        stairs.carry(body, frame.tick);
        movement::step(
            body,
            frame.movement,
            &restraint.params(params, frame.tick),
            world,
        );
    }

    /// Runs one client tick with this intent and returns the input packet to
    /// send. `action` is a cast (spell index + 1, 0 = none) at `target`
    /// (entity, 0 = none) and `aim` (a world point).
    pub fn step(&mut self, movement: MoveInput, action: u8, target: u32, aim: Vec3) -> Vec<u8> {
        self.tick += 1;
        self.seq += 1;
        let mut frame = InputFrame {
            tick: self.tick,
            movement,
            action,
            target: if action == 0 { 0 } else { target },
            aim: [0; 3],
        };
        if action != 0 {
            frame = frame.aimed_at(aim);
        }
        let after = match self.body.as_mut() {
            Some(body) => {
                self.prev_pos = body.pos;
                Self::simulate(
                    &mut self.world,
                    &mut self.stairs,
                    &self.params,
                    &self.restraint,
                    body,
                    &frame,
                    self.dead,
                );
                *body
            }
            None => Body::default(),
        };
        self.history.push_back(Predicted {
            seq: self.seq,
            frame,
            after,
        });
        while self.history.len() > 240 {
            self.history.pop_front();
        }
        self.sent.push_back(frame);
        while self.sent.len() > REDUNDANCY {
            self.sent.pop_front();
        }
        realm_proto::encode_inputs(&InputBatch {
            newest_seq: self.seq,
            ack_snapshot: self.acked,
            inputs: self.sent.iter().copied().collect(),
        })
    }

    /// Handles a datagram from the server; `local_ticks` is the caller's
    /// clock in ticks (seconds x 30) when it arrived.
    pub fn on_datagram(&mut self, bytes: &[u8], local_ticks: f64) {
        let snapshots = &self.snapshots;
        let decoded = realm_proto::decode_snapshot(bytes, |tick| {
            snapshots
                .iter()
                .find(|(t, _)| *t == tick)
                .map(|(_, set)| set.as_slice())
        });
        let snapshot = match decoded {
            Ok(s) => s,
            Err(_) => {
                self.stats.decode_errors += 1;
                return;
            }
        };
        self.stats.snapshots += 1;
        // The newest snapshot never arrives early, only late: the clock
        // follows the highest offset seen, easing down slowly.
        let offset = f64::from(snapshot.tick) - local_ticks;
        self.clock_offset = Some(match self.clock_offset {
            None => offset,
            Some(old) if offset > old => offset,
            Some(old) => old + (offset - old) * 0.02,
        });
        // A client that dropped steps in a stall (FixedStep runs at most 8 a
        // frame) would label its inputs further and further behind the
        // server; it catches its tick up to the server's instead.
        if let Some(now) = self.server_tick_at(local_ticks)
            && f64::from(self.tick) + 0.5 < now
        {
            self.tick = now.ceil() as u32;
        }
        if snapshot.tick > self.acked {
            self.acked = snapshot.tick;
        }
        self.own_hp = snapshot.own_hp;
        if !self
            .snapshots
            .back()
            .is_some_and(|(t, _)| *t > snapshot.tick)
        {
            self.own_vitals = snapshot.own_vitals;
        }
        let was_dead = self.dead;
        let mut held = false;
        if !self
            .snapshots
            .back()
            .is_some_and(|(t, _)| *t > snapshot.tick)
        {
            // Only the newest snapshot says whether the player is dead now,
            // and what holds its body.
            self.dead = snapshot.own_hp == 0;
            // A respawn and a death between two received snapshots leave
            // `dead` as it was; the count still moved.
            let life_moved = self.life.is_some_and(|l| l != snapshot.own_life);
            self.life = Some(snapshot.own_life);
            held = life_moved
                || (snapshot.own_restraint != self.restraint
                    && snapshot.own_restraint != Restraint::default());
            self.restraint = snapshot.own_restraint;
            self.own_status = snapshot.own_status;
        }
        self.reconcile(&snapshot, was_dead != self.dead || held);
        let pos = self.snapshots.partition_point(|(t, _)| *t < snapshot.tick);
        if self
            .snapshots
            .get(pos)
            .is_none_or(|(t, _)| *t != snapshot.tick)
        {
            self.snapshots
                .insert(pos, (snapshot.tick, snapshot.entities));
        }
        while self.snapshots.len() > KEEP_SNAPSHOTS {
            self.snapshots.pop_front();
        }
    }

    /// The server ran inputs up to `last_input_seq` and its body is
    /// `snapshot.own`: rewind to it and replay the inputs it has not seen.
    /// `life_changed`: this snapshot is the first to show a death, a
    /// respawn or a new hold on the body, so a difference is the server's
    /// doing, not a misprediction.
    fn reconcile(&mut self, snapshot: &Snapshot, life_changed: bool) {
        let confirmed = snapshot.last_input_seq;
        // A snapshot that arrives after a newer one (reordered on the way)
        // confirms nothing new.
        if self.body.is_some() && confirmed <= self.confirmed {
            return;
        }
        self.confirmed = confirmed;
        let predicted = self
            .history
            .iter()
            .find(|p| p.seq == confirmed)
            .map(|p| p.after);
        while self.history.front().is_some_and(|p| p.seq <= confirmed) {
            self.history.pop_front();
        }
        let Some(current) = self.body else {
            // First snapshot: adopt the server's body, then replay what is
            // already on its way.
            let mut body = snapshot.own;
            for p in &mut self.history {
                Self::simulate(
                    &mut self.world,
                    &mut self.stairs,
                    &self.params,
                    &self.restraint,
                    &mut body,
                    &p.frame,
                    self.dead,
                );
                p.after = body;
            }
            self.prev_pos = body.pos;
            self.body = Some(body);
            return;
        };
        // A death, a respawn or a new hold changes how the inputs still on
        // their way run, even when the confirmed one matched: replay them.
        if predicted == Some(snapshot.own) && !life_changed {
            return;
        }
        let mut body = snapshot.own;
        for p in &mut self.history {
            Self::simulate(
                &mut self.world,
                &mut self.stairs,
                &self.params,
                &self.restraint,
                &mut body,
                &p.frame,
                self.dead,
            );
            p.after = body;
            self.stats.replayed += 1;
        }
        let moved = (body.pos - current.pos).length();
        if life_changed {
            if body != current {
                self.stats.server_moves += 1;
            }
        } else if predicted.is_some() {
            self.stats.corrections += 1;
            self.stats.max_correction = self.stats.max_correction.max(moved);
        }
        self.body = Some(body);
    }

    /// The server tick at `local_ticks`, estimated from snapshot arrivals.
    #[must_use]
    pub fn server_tick_at(&self, local_ticks: f64) -> Option<f64> {
        self.clock_offset.map(|o| local_ticks + o)
    }

    /// Every remote entity drawn at `local_ticks`: interpolated between the
    /// two snapshots around (server tick - INTERPOLATION_TICKS).
    #[must_use]
    pub fn remote_entities(&self, local_ticks: f64) -> Vec<RemoteEntity> {
        let Some(now) = self.server_tick_at(local_ticks) else {
            return Vec::new();
        };
        let render = now - INTERPOLATION_TICKS;
        let Some(newest) = self.snapshots.back() else {
            return Vec::new();
        };
        let after = self
            .snapshots
            .iter()
            .position(|(t, _)| f64::from(*t) >= render);
        let (a, b, f) = match after {
            Some(0) | None => (newest, newest, 0.0),
            Some(i) => {
                let (a, b) = (&self.snapshots[i - 1], &self.snapshots[i]);
                let span = f64::from(b.0 - a.0).max(1.0);
                (
                    a,
                    b,
                    ((render - f64::from(a.0)) / span).clamp(0.0, 1.0) as f32,
                )
            }
        };
        let yaw = |y: u16| f32::from(y) * (core::f32::consts::TAU / 65_536.0);
        let mut out = Vec::with_capacity(b.1.len());
        for (id, now_state) in &b.1 {
            if *id == self.me {
                continue;
            }
            let then: &EntityState =
                a.1.binary_search_by_key(id, |e| e.0)
                    .ok()
                    .map_or(now_state, |i| &a.1[i].1);
            let turn = (now_state.yaw.wrapping_sub(then.yaw) as i16) as f32
                * (core::f32::consts::TAU / 65_536.0);
            out.push(RemoteEntity {
                id: *id,
                kind: now_state.kind,
                pos: then.pos + (now_state.pos - then.pos) * f,
                yaw: yaw(then.yaw) + turn * f,
                state: now_state.state,
                hp: now_state.hp,
                status: now_state.status,
            });
        }
        out
    }

    /// Ticks per second, for callers converting their clock.
    pub const HZ: f64 = SIM_HZ as f64;
}
