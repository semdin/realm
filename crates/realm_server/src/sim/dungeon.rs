//! Dungeons on the map server: the gate on an outer map (what the dungeon
//! asks of the party, the ready check, the launch) and, on a dungeon map,
//! its copies and their runs.
//!
//! A dungeon map holds up to COPIES copies side by side (copy_offset); each
//! run is a director walking the dungeon's steps: a step fires on its
//! trigger (enter, a step cleared, every creature cleared, a creature below
//! a share of its health, a player past a line), spawns its creatures at the
//! run's level, opens and closes gates (scheduled GATE_LEAD ticks ahead, so
//! clients predict them), says its message, and the final step completes the
//! run. The clock starts when the start gate opens after the party gathered
//! and counted down; deaths add time and may spend the party's lives; the run
//! ends at `medals.limit` pars of real time. A full clear inside the medal
//! times earns a medal. Kills pay every member in the copy; the end pays the
//! completion share, oril and a personal chest to members with a daily right
//! left, and records the clear.
//!
//! The gate on the outer map holds the party to the rules (leader, size,
//! gathered at the gate, alive, not riding, duelling or fighting, not in
//! another run, level, unlocked difficulty, level spread, the leader's keys),
//! runs the ready check, asks the coordinator for a copy and sends the party
//! in together. A member who walks out may walk back in through the door
//! while the copy stands.
//!
//! The old game's `authority` dungeon gate and `dungeon_director`, with
//! these faults fixed: a timed-out run records no clear; the time limit runs
//! on real time (death penalties no longer bring it closer); a step fired by
//! a creature's health spawns nothing once that creature is dead; a ready
//! check ends as soon as the party changes; replaying is the leader's.

use bevy_ecs::prelude::*;
use realm_proto::control::{
    DungeonMsg, GateMember, HazardView, ReadyView, RunResult, RunView, ServerMsg,
};
use realm_proto::coord::{MapMsg, RunSpec, RunSummary};
use realm_rules::dungeons::{
    self, DIFFICULTIES, RANK_CLEAR, SpawnEntry, Trigger, copy_at, copy_offset,
};
use realm_rules::travel::{Arrival, Landing, Trip, TripKind};
use realm_sim::{SIM_HZ, Vec3};

use super::{
    ConnId, Mob, MobMode, NetId, Player, STATE_IDLE, ServerDice, Sim, planar_distance, unit,
    xorshift,
};
use crate::game::{BossSetup, Pack, PackKind};

/// Gate changes take effect this many ticks after they are decided.
pub(super) const GATE_LEAD: u32 = 15;
const DIRECTOR_TICKS: u32 = 8;
const GATHER_TICKS: u32 = 45 * SIM_HZ;
const EMPTY_TTL_TICKS: u32 = 300 * SIM_HZ;
const RUN_LEASH: f32 = 70.0;
const DEFAULT_ASSIST: f32 = 22.0;
const VERTICAL_GATHER: f32 = 6.0;
/// A launch the coordinator never answered is given up after this.
const LAUNCH_WAIT_TICKS: u32 = 10 * SIM_HZ;
/// The gate's combat lock.
const GATE_COMBAT_TICKS: u32 = 5 * SIM_HZ;
const RING: f32 = 1.4;

fn v3(p: [f32; 3]) -> Vec3 {
    Vec3::new(p[0], p[1], p[2])
}

pub(super) fn offset_of(copy: u8) -> Vec3 {
    v3(copy_offset(copy))
}

/// A creature a run fielded.
pub(super) struct RunMob {
    pub entity: Entity,
    pub step: usize,
    pub forces: u32,
    pub credited: bool,
    /// Its kill experience, paid to the members when it falls.
    pub exp: u32,
    pub level: u32,
    pub boss_name: Option<String>,
    pub role: String,
    /// Its numbers before curses (bolster and rage scale these).
    pub base_hp: f32,
    pub base_attack: f32,
    pub base_speed: f32,
    pub stacks: u8,
    pub raged: bool,
    /// A boss: when its current fight began (its legendary rage counts
    /// from the pull, again after every reset).
    pub pulled_at: Option<u32>,
    /// An egg sac: when it hatches and into what (mob, role).
    pub hatch: Option<(u32, Vec<(String, String)>)>,
    /// Marks the run gave it (curse_bleed: its blows bleed).
    pub marks: Vec<String>,
}

/// A curse's mark on a run's floor.
pub(super) struct Hazard {
    pub view: HazardView,
    pub pos: Vec3,
    pub done: bool,
    /// A push instead of damage (the breath): direction x speed, lift.
    pub push: Option<(Vec3, f32)>,
}

/// The sluice wheel is rung from this close.
const CHIME_RADIUS: f32 = 2.6;

pub(super) struct RunMember {
    pub character: u64,
    pub rewarded: bool,
    pub first_run: bool,
}

pub(super) struct Run {
    pub copy: u8,
    pub dungeon: String,
    pub difficulty: usize,
    pub ref_level: u16,
    pub roster: Vec<RunMember>,
    /// 0 gathering, 1 countdown, 2 running, 3 over.
    pub phase: u8,
    pub phase_end: u32,
    pub start_tick: u32,
    pub end_tick: u32,
    pub done: Vec<bool>,
    pub step_pack: Vec<Option<usize>>,
    pub mobs: Vec<RunMob>,
    pub forces: u32,
    pub forces_total: u32,
    pub deaths: u16,
    pub lives_left: i32,
    pub broken: bool,
    pub complete: bool,
    pub result: Option<RunResult>,
    pub message: String,
    pub step: String,
    /// Steps whose closed gates a wipe opened again.
    pub unlocked: Vec<usize>,
    pub empty_since: Option<u32>,
    pub paid: bool,
    pub sent: Option<RunView>,
    pub affixes: Vec<String>,
    pub hazards: Vec<Hazard>,
    pub chill_next: u32,
    pub storm_next: u32,
    pub chime: Option<Chime>,
    /// Per dungeon hazard (the breath): when it next blows.
    pub breath_next: Vec<u32>,
    /// The Silk Queen's cocoons: (wrapped player, cocoon, deadline, health
    /// share lost if it is not broken in time).
    pub cocoons: Vec<(Entity, Entity, u32, f32)>,
    /// When a step last spoke (its line stands a while before any nag).
    pub said_at: u32,
}

/// The sluice wheel by a sleeping guardian (Wheelwarden).
pub(super) struct Chime {
    pub at: Vec3,
    pub scale: f32,
    pub body: Entity,
    pub ringer: Option<Entity>,
    pub combat_at_start: u32,
    pub start: u32,
    pub end: u32,
    pub ready: u32,
}

/// A ready check on an outer map.
pub(super) struct Check {
    pub id: u32,
    pub portal: String,
    pub dungeon: String,
    pub difficulty: usize,
    pub leader: u64,
    pub roster: Vec<u64>,
    pub ready: Vec<u64>,
    pub ends: u32,
    /// Another run from this finished copy (0: from the gate).
    pub replay: u8,
}

/// Where a party must stand to go in: at the gate, or (another run) in
/// its finished copy.
pub(super) enum Gather {
    Gate(realm_rules::travel::Portal),
    Copy(u8),
}

/// A launch waiting for its copy.
pub(super) struct Launch {
    pub req: u64,
    pub portal: String,
    pub leader: u64,
    pub roster: Vec<u64>,
    pub keys: u32,
    pub since: u32,
}

/// A party going into its copy: the leader first. Its trip pays the keys
/// when its seat is confirmed, and only then do the others follow.
pub(super) struct Boarding {
    pub leader: u64,
    pub roster: Vec<u64>,
    pub copy: u8,
    pub map: String,
    pub spawn: String,
    pub label: String,
    pub since: u32,
}

/// An egg sac due to hatch: (its index in the run, the sac, where, what
/// hatches (mob, role), its step).
type Hatching = (usize, Entity, Vec3, Vec<(String, String)>, usize);

impl Sim {
    // ------------------------------------------------------------ helpers

    pub(super) fn copy_of(&self, pos: Vec3) -> u8 {
        if self.instanced { copy_at(pos.x) } else { 0 }
    }

    fn run_index(&self, copy: u8) -> Option<usize> {
        let i = usize::from(copy).checked_sub(1)?;
        self.runs.get(i).and_then(Option::as_ref).map(|_| i)
    }

    /// Players standing in copy `copy` (entity, conn).
    fn in_copy(&self, copy: u8) -> Vec<(Entity, ConnId)> {
        let mut out: Vec<(Entity, ConnId)> = self
            .clients
            .iter()
            .filter_map(|(conn, c)| {
                let p = self.world.get::<Player>(c.entity)?;
                (self.copy_of(p.body.pos) == copy).then_some((c.entity, *conn))
            })
            .collect();
        out.sort_unstable_by_key(|(_, c)| *c);
        out
    }

    /// The dungeon gate `portal` on this map: its dungeon, the portal.
    fn gate_of(
        &self,
        portal: &str,
    ) -> Option<(
        realm_rules::travel::Portal,
        realm_rules::dungeons::DungeonDef,
    )> {
        let rules = self.rules();
        let p = rules
            .travel
            .portals
            .iter()
            .find(|p| p.id == portal && p.map == self.game.map)?
            .clone();
        let d = rules.dungeons.on_map(&p.to_map)?.clone();
        Some((p, d))
    }

    // ------------------------------------------------------- the dungeon map

    /// Where a joining character goes on a dungeon map: the copy of its
    /// run (from its trip, its saved place, or any copy that holds it);
    /// None: it has no run here.
    pub(super) fn copy_for_join(
        &self,
        character: u64,
        arrival_copy: u8,
        saved_x: Option<f32>,
    ) -> Option<u8> {
        let holds = |copy: u8| {
            self.run_index(copy).is_some_and(|i| {
                self.runs[i]
                    .as_ref()
                    .is_some_and(|r| r.roster.iter().any(|m| m.character == character))
            })
        };
        if arrival_copy != 0 && holds(arrival_copy) {
            return Some(arrival_copy);
        }
        if let Some(x) = saved_x
            && holds(copy_at(x))
        {
            return Some(copy_at(x));
        }
        (1..=dungeons::COPIES).find(|c| holds(*c))
    }

    /// A character on a dungeon map with no run here leaves by its first
    /// exit (not a reward exit).
    pub(super) fn eject_from_dungeon(&mut self, conn: ConnId, entity: Entity) {
        let rules = self.rules();
        let exit = rules
            .travel
            .portals
            .iter()
            .filter(|p| p.map == self.game.map)
            .min_by_key(|p| p.id.contains("reward"))
            .cloned();
        let Some(exit) = exit else { return };
        let trip = Trip {
            arrival: Arrival {
                map: exit.to_map.clone(),
                landing: Landing::Spawn(exit.to_spawn.clone()),
                kind: TripKind::Door,
                copy: 0,
            },
            label: rules
                .travel
                .maps
                .get(&exit.to_map)
                .map_or_else(|| exit.label.clone(), |m| m.display.clone()),
            cost: None,
            combat_lock_ms: 0,
        };
        self.start_trip(conn, entity, trip, false);
    }

    /// A player was admitted into copy `copy`: the copy's gates and run.
    pub(super) fn copy_joined(&mut self, conn: ConnId, copy: u8) {
        let changes: Vec<(String, u32, bool)> = self
            .gates
            .gates
            .iter()
            .filter(|g| g.copy == copy)
            .flat_map(|g| g.changes.iter().map(|(t, o)| (g.id.clone(), *t, *o)))
            .collect();
        for (id, tick, open) in changes {
            self.send_control(conn, &ServerMsg::Gate { id, tick, open });
        }
        if let Some(i) = self.run_index(copy) {
            let view = self.run_view(i);
            self.send_control(conn, &ServerMsg::Dungeon(Box::new(DungeonMsg::State(view))));
        }
    }

    /// The coordinator asks for a copy for this run.
    pub(super) fn open_copy(&mut self, req: u64, spec: &RunSpec) {
        let copy = self.open_copy_here(spec);
        self.coord_send(MapMsg::CopyOpened { req, copy });
        if copy != 0 {
            self.runs_changed();
        }
    }

    /// Opens a copy for `spec` on this map; its number (0: none free).
    fn open_copy_here(&mut self, spec: &RunSpec) -> u8 {
        let rules = self.rules();
        let free = self.runs.iter().position(Option::is_none);
        let def = rules
            .dungeons
            .dungeons
            .get(&spec.dungeon)
            .filter(|d| d.map == self.game.map);
        let (Some(i), Some(def)) = (free, def) else {
            return 0;
        };
        let copy = (i + 1) as u8;
        // A character holds one run at a time: older copies let it go.
        let chars: Vec<u64> = spec.roster.iter().map(|m| m.0).collect();
        for run in self.runs.iter_mut().flatten() {
            run.roster.retain(|m| !chars.contains(&m.character));
        }
        let difficulty = usize::from(spec.difficulty).min(DIFFICULTIES.len() - 1);
        let diff = &rules.dungeons.difficulties[difficulty];
        let party = spec.roster.len();
        // What a full clear counts: every forces-bearing creature of the
        // steps this difficulty fields.
        let affixes = self
            .dev_dungeon_affixes
            .clone()
            .unwrap_or_else(|| spec.affixes.clone());
        let teeming = affixes.iter().any(|a| a == "teeming");
        let extra_share = rules.dungeons.affixes.num("teeming", "extra", 0.25);
        let mut forces_total = 0;
        for step in &def.steps {
            if step.min_difficulty > difficulty {
                continue;
            }
            let mut entries: Vec<&SpawnEntry> = step.spawn.iter().collect();
            // Teeming's extra groups count towards a full clear too.
            let trash: Vec<&SpawnEntry> = entries
                .iter()
                .copied()
                .filter(|e| e.role == "trash")
                .collect();
            if teeming {
                let extra = (trash.len() as f32 * extra_share).ceil() as usize;
                entries.extend(trash.into_iter().take(extra));
            }
            for e in entries {
                if e.min_difficulty > difficulty {
                    continue;
                }
                let forces = rules.dungeons.roles.get(&e.role).map_or(0, |r| r.forces);
                forces_total += forces * rules.dungeons.group_count(e, difficulty, party);
            }
        }
        self.gates.reset(copy);
        let tick = self.tick;
        self.runs[i] = Some(Run {
            copy,
            dungeon: spec.dungeon.clone(),
            difficulty,
            ref_level: spec.ref_level,
            roster: spec
                .roster
                .iter()
                .map(|(character, _, _, rewarded, first_run)| RunMember {
                    character: *character,
                    rewarded: *rewarded,
                    first_run: *first_run,
                })
                .collect(),
            phase: 0,
            phase_end: tick + GATHER_TICKS,
            start_tick: 0,
            end_tick: 0,
            done: vec![false; def.steps.len()],
            step_pack: vec![None; def.steps.len()],
            mobs: Vec::new(),
            forces: 0,
            forces_total,
            deaths: 0,
            lives_left: diff.lives,
            broken: false,
            complete: false,
            result: None,
            message: String::new(),
            step: String::new(),
            unlocked: Vec::new(),
            empty_since: None,
            paid: false,
            sent: None,
            affixes,
            hazards: Vec::new(),
            chill_next: 0,
            storm_next: 0,
            chime: None,
            breath_next: vec![0; def.hazards.len()],
            cocoons: Vec::new(),
            said_at: 0,
        });
        println!(
            "[dungeon] copy {copy} of {} opened: {} at {} for {party} (level {})",
            spec.dungeon, diff.id, spec.ref_level, spec.ref_level
        );
        copy
    }

    /// Tells the coordinator this map's live copies (when they change).
    fn runs_changed(&mut self) {
        let list = self.run_summaries();
        if list != self.runs_told {
            self.runs_told.clone_from(&list);
            self.coord_send(MapMsg::Runs(list));
        }
    }

    fn run_summaries(&self) -> Vec<RunSummary> {
        let rules = self.rules();
        let tick = self.tick;
        self.runs
            .iter()
            .flatten()
            .map(|r| {
                let par = rules.dungeons.dungeons.get(&r.dungeon).map_or(600.0, |d| {
                    d.par_s * rules.dungeons.difficulties[r.difficulty].par_mult
                });
                let inside = self.in_copy(r.copy).len() as u8;
                let left_s = match (r.empty_since, r.phase) {
                    (Some(since), _) => (since + EMPTY_TTL_TICKS).saturating_sub(tick) / SIM_HZ,
                    (None, 2) => {
                        let limit = (par * rules.dungeons.medals.limit) as u32 * SIM_HZ;
                        (r.start_tick + limit).saturating_sub(tick) / SIM_HZ
                    }
                    _ => u32::MAX,
                };
                RunSummary {
                    map: self.game.map.clone(),
                    copy: r.copy,
                    dungeon: r.dungeon.clone(),
                    difficulty: r.difficulty as u8,
                    roster: r.roster.iter().map(|m| m.character).collect(),
                    complete: r.complete,
                    forces: r.forces,
                    forces_total: r.forces_total,
                    // Ten-second steps keep the registry quiet.
                    left_s: if left_s == u32::MAX {
                        -1
                    } else {
                        (left_s / 10 * 10) as i32
                    },
                    inside,
                }
            })
            .collect()
    }

    fn run_view(&self, i: usize) -> RunView {
        let rules = self.rules();
        let Some(r) = self.runs[i].as_ref() else {
            return RunView::default();
        };
        let def = rules.dungeons.dungeons.get(&r.dungeon);
        let diff = &rules.dungeons.difficulties[r.difficulty];
        let par = def.map_or(600.0, |d| d.par_s * diff.par_mult);
        let left = if r.phase == 2 {
            r.mobs
                .iter()
                .filter(|m| {
                    self.world
                        .get::<Mob>(m.entity)
                        .is_some_and(|x| x.mode != MobMode::Dead)
                })
                .count() as u32
        } else {
            0
        };
        RunView {
            dungeon: r.dungeon.clone(),
            difficulty: r.difficulty as u8,
            ref_level: r.ref_level,
            phase: r.phase,
            countdown_end: if r.phase == 1 { r.phase_end } else { 0 },
            start_tick: r.start_tick,
            penalty_s: f32::from(r.deaths) * diff.death_penalty_s,
            par_s: par,
            limit_s: par * rules.dungeons.medals.limit,
            step: r.step.clone(),
            message: r.message.clone(),
            forces: r.forces,
            forces_total: r.forces_total,
            deaths: r.deaths,
            lives_left: r.lives_left,
            broken: r.broken,
            bosses: r
                .mobs
                .iter()
                .filter_map(|m| {
                    let name = m.boss_name.clone()?;
                    let down = self
                        .world
                        .get::<Mob>(m.entity)
                        .is_none_or(|x| x.mode == MobMode::Dead);
                    Some((name, down))
                })
                .collect(),
            left,
            complete: r.complete,
            result: r.result.clone(),
            affixes: r.affixes.clone(),
            hazards: r
                .hazards
                .iter()
                .filter(|h| !h.done)
                .map(|h| h.view.clone())
                .collect(),
            chime: r.chime.as_ref().map(|c| realm_proto::control::ChimeView {
                at: [c.at.x, c.at.y, c.at.z],
                radius: CHIME_RADIUS,
                ringer: c.ringer.map_or(0, |e| self.net_id_of(e)),
                start_tick: if c.ringer.is_some() { c.start } else { 0 },
                end_tick: if c.ringer.is_some() { c.end } else { 0 },
                ready_tick: c.ready,
            }),
        }
    }

    /// Sends the run's view to its players when it changed.
    fn publish(&mut self, i: usize) {
        let view = self.run_view(i);
        let Some(run) = self.runs[i].as_mut() else {
            return;
        };
        if run.sent.as_ref() == Some(&view) {
            return;
        }
        run.sent = Some(view.clone());
        let copy = run.copy;
        for (_, conn) in self.in_copy(copy) {
            self.send_control(
                conn,
                &ServerMsg::Dungeon(Box::new(DungeonMsg::State(view.clone()))),
            );
        }
    }

    fn say(&mut self, i: usize, message: &str) {
        let tick = self.tick;
        if let Some(r) = self.runs[i].as_mut()
            && !message.is_empty()
        {
            r.message = message.to_owned();
            r.said_at = tick;
        }
    }

    /// Opens (or closes) a gate of run `i`'s copy, GATE_LEAD ticks ahead,
    /// and tells the copy's players.
    fn set_gate(&mut self, i: usize, id: &str, open: bool) {
        let Some(copy) = self.runs[i].as_ref().map(|r| r.copy) else {
            return;
        };
        let tick = self.tick + GATE_LEAD;
        let current = self
            .gates
            .gates
            .iter()
            .find(|g| g.copy == copy && g.id == id)
            .map(|g| g.open_at(tick));
        if current.is_none() || current == Some(open) {
            return;
        }
        self.gates.schedule(copy, id, tick, open);
        println!(
            "[dungeon] copy {copy}: gate {id} {} at tick {tick}",
            if open { "opens" } else { "closes" }
        );
        for (_, conn) in self.in_copy(copy) {
            self.send_control(
                conn,
                &ServerMsg::Gate {
                    id: id.to_owned(),
                    tick,
                    open,
                },
            );
        }
    }

    /// The director, every DIRECTOR_TICKS.
    pub(super) fn tick_runs(&mut self) {
        if !self.instanced || !self.tick.is_multiple_of(DIRECTOR_TICKS) {
            return;
        }
        for i in 0..self.runs.len() {
            if self.runs[i].is_none() {
                continue;
            }
            self.direct(i);
            if self.runs[i].is_some() {
                self.publish(i);
            }
        }
        if self.tick.is_multiple_of(2 * SIM_HZ) {
            self.runs_changed();
        }
    }

    fn direct(&mut self, i: usize) {
        let tick = self.tick;
        let rules = self.rules();
        let Some(copy) = self.runs[i].as_ref().map(|r| r.copy) else {
            return;
        };
        let Some(def) = self.runs[i]
            .as_ref()
            .and_then(|r| rules.dungeons.dungeons.get(&r.dungeon))
            .cloned()
        else {
            return;
        };
        let inside = self.in_copy(copy);
        // An empty copy closes after its time.
        {
            let r = self.runs[i].as_mut().expect("live run");
            if inside.is_empty() {
                let since = *r.empty_since.get_or_insert(tick);
                if tick > since + EMPTY_TTL_TICKS {
                    self.close_copy(i);
                    return;
                }
            } else {
                r.empty_since = None;
            }
        }
        let (phase, phase_end) = {
            let r = self.runs[i].as_ref().expect("live run");
            (r.phase, r.phase_end)
        };
        match phase {
            0 => {
                let arrived = {
                    let r = self.runs[i].as_ref().expect("live run");
                    r.roster.iter().all(|m| {
                        self.player_of(m.character).is_some_and(|(_, e)| {
                            self.world.get::<Player>(e).is_some_and(|p| {
                                self.copy_of(p.body.pos) == copy && p.trip.is_none()
                            })
                        })
                    })
                };
                if arrived || tick >= phase_end {
                    let countdown = (rules.dungeons.group.countdown_s * SIM_HZ as f32) as u32;
                    let r = self.runs[i].as_mut().expect("live run");
                    r.phase = 1;
                    r.phase_end = tick + countdown;
                }
                return;
            }
            1 => {
                if tick >= phase_end {
                    let hazard_mult = rules.dungeons.difficulties
                        [self.runs[i].as_ref().map_or(0, |r| r.difficulty)]
                    .hazard_mult;
                    let a = &rules.dungeons.affixes;
                    let r = self.runs[i].as_mut().expect("live run");
                    r.phase = 2;
                    r.start_tick = tick + GATE_LEAD;
                    r.chill_next = tick
                        + (a.num("chill", "every_s", 45.0) * hazard_mult * SIM_HZ as f32) as u32;
                    r.storm_next = tick
                        + (a.num("storm", "every_s", 12.0) * hazard_mult * SIM_HZ as f32) as u32;
                    self.set_gate(i, "start", true);
                    // Development: straight to a step, those before it done.
                    if let Some(start) = self.dev_dungeon_start.clone()
                        && let Some(k) = def.steps.iter().position(|s| s.id == start)
                    {
                        for s in 0..k {
                            if let Some(r) = self.runs[i].as_mut() {
                                r.done[s] = true;
                            }
                            for g in def.steps[s].open.clone() {
                                self.set_gate(i, &g, true);
                            }
                        }
                    }
                }
                return;
            }
            3 => return,
            _ => {}
        }
        self.credit_forces(i);
        self.curse_tick(i);
        self.chime_tick(i);
        self.lair_tick(i);
        self.breath_tick(i, &def);
        self.wipe_lock(i, &def);
        // The chain: steps in order, the first unmet one waits.
        let difficulty = self.runs[i].as_ref().map_or(0, |r| r.difficulty);
        for s in 0..def.steps.len() {
            let step = &def.steps[s];
            if step.optional || step.min_difficulty > difficulty {
                continue;
            }
            if self.runs[i].as_ref().is_some_and(|r| r.done[s]) {
                continue;
            }
            if !self.trigger_met(i, &def, s) {
                // The last step nags, once the line before it has stood
                // a while.
                if matches!(step.on, Trigger::ClearedAll)
                    && let Some(r) = self.runs[i].as_mut()
                    && tick >= r.said_at + 10 * SIM_HZ
                {
                    r.message =
                        "Creatures still stand - clear them all to finish the run.".to_owned();
                }
                break;
            }
            self.act(i, &def, s);
            if self.runs[i].as_ref().is_none_or(|r| r.phase == 3) {
                return;
            }
        }
        // Side rooms fire on their own.
        for s in 0..def.steps.len() {
            let step = &def.steps[s];
            if !step.optional || step.min_difficulty > difficulty {
                continue;
            }
            if self.runs[i].as_ref().is_some_and(|r| !r.done[s]) && self.trigger_met(i, &def, s) {
                self.act(i, &def, s);
            }
        }
        // The time limit runs on real time.
        let par = def.par_s * rules.dungeons.difficulties[difficulty].par_mult;
        let limit = (par * rules.dungeons.medals.limit * SIM_HZ as f32) as u32;
        if let Some(start) = self.runs[i].as_ref().map(|r| r.start_tick)
            && tick >= start + limit
        {
            self.time_up(i, &def);
        }
    }

    /// Forces of creatures that fell (or went) are credited.
    fn credit_forces(&mut self, i: usize) {
        let gone: Vec<usize> = {
            let Some(r) = self.runs[i].as_ref() else {
                return;
            };
            r.mobs
                .iter()
                .enumerate()
                .filter(|(_, m)| {
                    !m.credited
                        && self
                            .world
                            .get::<Mob>(m.entity)
                            .is_none_or(|x| x.mode == MobMode::Dead)
                })
                .map(|(k, _)| k)
                .collect()
        };
        for k in gone {
            self.run_mob_fell(i, k);
        }
    }

    fn living(&self, i: usize, step: Option<usize>) -> usize {
        self.runs[i].as_ref().map_or(0, |r| {
            r.mobs
                .iter()
                .filter(|m| step.is_none_or(|s| m.step == s))
                .filter(|m| {
                    self.world
                        .get::<Mob>(m.entity)
                        .is_some_and(|x| x.mode != MobMode::Dead)
                })
                .count()
        })
    }

    fn trigger_met(&self, i: usize, def: &realm_rules::dungeons::DungeonDef, s: usize) -> bool {
        let Some(r) = self.runs[i].as_ref() else {
            return false;
        };
        let step_index = |id: &str| def.steps.iter().position(|x| x.id == id);
        match &def.steps[s].on {
            Trigger::Enter => true,
            Trigger::Cleared(id) => step_index(id).is_some_and(|k| {
                r.done[k] && r.mobs.iter().any(|m| m.step == k) && self.living(i, Some(k)) == 0
            }),
            Trigger::ClearedAll => self.living(i, None) == 0,
            Trigger::HpBelow(id, share) => step_index(id).is_some_and(|k| {
                r.mobs.iter().filter(|m| m.step == k).any(|m| {
                    self.world
                        .get::<Mob>(m.entity)
                        .is_none_or(|x| x.mode == MobMode::Dead || x.hp < x.max_hp * share)
                })
            }),
            Trigger::Area(z) => {
                let offset = offset_of(r.copy);
                self.in_copy(r.copy).iter().any(|(e, _)| {
                    self.world
                        .get::<Player>(*e)
                        .is_some_and(|p| p.dead_until == 0 && p.body.pos.z - offset.z < *z)
                })
            }
        }
    }

    /// A step fires: spawns, gates, its message, the end.
    fn act(&mut self, i: usize, def: &realm_rules::dungeons::DungeonDef, s: usize) {
        let step = def.steps[s].clone();
        if let Some(r) = self.runs[i].as_mut() {
            r.done[s] = true;
            if !step.optional {
                r.step.clone_from(&step.id);
            }
        }
        // A step fired by a creature's health brings no adds once it fell.
        let spawn = match &step.on {
            Trigger::HpBelow(id, _) => {
                let k = def.steps.iter().position(|x| &x.id == id);
                k.is_some_and(|k| self.living(i, Some(k)) > 0)
            }
            _ => true,
        };
        if spawn && !step.spawn.is_empty() {
            self.spawn_step(i, s, &step.spawn);
        }
        for g in &step.open {
            self.set_gate(i, g, true);
        }
        for g in &step.close {
            self.set_gate(i, g, false);
        }
        // The Silk Queen's floor: venom pools, webs.
        for pool in &step.pools {
            self.lay_pool(i, pool);
        }
        if let Some(c) = &step.cocoon {
            self.wrap_in_cocoon(i, s, c);
        }
        self.say(i, &step.message);
        if step.complete {
            self.finish(i, def, false, step.chest.as_ref().map(|c| c.1));
        }
    }

    /// A pool on the run's floor: venom that bites each second, or a web
    /// (no bite) that slows.
    fn lay_pool(&mut self, i: usize, pool: &realm_rules::dungeons::Pool) {
        let tick = self.tick;
        let Some(copy) = self.runs[i].as_ref().map(|r| r.copy) else {
            return;
        };
        let at = self.settle(v3(pool.at) + offset_of(copy));
        let share = if pool.kind == "web" {
            0.0
        } else {
            pool.hp_share_s
        };
        let until = tick + (pool.duration_s * SIM_HZ as f32) as u32;
        self.add_hazard(i, "pool", at, pool.radius, 0, until, share);
    }

    /// The Silk Queen spins a living player into a cocoon: held fast until
    /// the cocoon breaks, the share of its health lost if it holds out.
    /// Only with two or more standing (one alone could never get free).
    fn wrap_in_cocoon(&mut self, i: usize, s: usize, c: &realm_rules::dungeons::Cocoon) {
        let tick = self.tick;
        let Some(copy) = self.runs[i].as_ref().map(|r| r.copy) else {
            return;
        };
        let living: Vec<Entity> = self
            .in_copy(copy)
            .into_iter()
            .map(|(e, _)| e)
            .filter(|e| {
                self.world
                    .get::<Player>(*e)
                    .is_some_and(|p| p.dead_until == 0)
            })
            .collect();
        if living.len() < 2 && !(self.dev_cocoon_solo && !living.is_empty()) {
            return;
        }
        let victim = living[(xorshift(&mut self.dice_state) as usize) % living.len()];
        let Some(at) = self.world.get::<Player>(victim).map(|p| p.body.pos) else {
            return;
        };
        let hold = (c.hold_s * SIM_HZ as f32) as u32;
        // The cocoon: a still thing to break, part of the step.
        let entry = SpawnEntry {
            mob: c.mob.clone(),
            role: "object".to_owned(),
            at: {
                let local = at - offset_of(copy);
                [local.x, local.y, local.z]
            },
            ..SpawnEntry::default()
        };
        let before = self.runs[i].as_ref().map_or(0, |r| r.mobs.len());
        self.spawn_step(i, s, std::slice::from_ref(&entry));
        let Some(cocoon) = self.runs[i]
            .as_ref()
            .and_then(|r| r.mobs.get(before))
            .map(|m| m.entity)
        else {
            return;
        };
        if let Some(mut p) = self.world.get_mut::<Player>(victim) {
            let now = p.last_input_tick + 1;
            p.restraint.lock(now, now + hold);
            p.afflictions.stun_until = p.afflictions.stun_until.max(tick + hold);
        }
        if let Some(r) = self.runs[i].as_mut() {
            r.cocoons.push((victim, cocoon, tick + hold, c.hp_share));
        }
    }

    /// Egg sacs that stood their time hatch; cocoons broken let their
    /// prisoner go, those that held out take their share.
    fn lair_tick(&mut self, i: usize) {
        let tick = self.tick;
        // Hatching.
        let due: Vec<Hatching> = self.runs[i]
            .as_ref()
            .map(|r| {
                r.mobs
                    .iter()
                    .enumerate()
                    .filter_map(|(k, m)| {
                        let (at, into) = m.hatch.as_ref()?;
                        if tick < *at {
                            return None;
                        }
                        let x = self.world.get::<Mob>(m.entity)?;
                        (x.mode != MobMode::Dead)
                            .then(|| (k, m.entity, x.pos, into.clone(), m.step))
                    })
                    .collect()
            })
            .unwrap_or_default();
        for (k, sac, pos, into, step) in due {
            if let Some(r) = self.runs[i].as_mut() {
                r.mobs[k].hatch = None;
            }
            self.mob_died(sac, None);
            let copy = self.runs[i].as_ref().map_or(0, |r| r.copy);
            let local = pos - offset_of(copy);
            let n = into.len().max(1) as f32;
            let entries: Vec<SpawnEntry> = into
                .iter()
                .enumerate()
                .map(|(j, (mob, role))| {
                    let a = core::f32::consts::TAU * j as f32 / n;
                    SpawnEntry {
                        mob: mob.clone(),
                        role: role.clone(),
                        at: [
                            local.x + libm::cosf(a) * 0.75,
                            local.y,
                            local.z + libm::sinf(a) * 0.75,
                        ],
                        ..SpawnEntry::default()
                    }
                })
                .collect();
            self.spawn_step(i, step, &entries);
            self.say(i, "An egg sac splits open!");
        }
        // Cocoons.
        let cocoons = self.runs[i]
            .as_ref()
            .map(|r| r.cocoons.clone())
            .unwrap_or_default();
        let mut keep = Vec::new();
        for (victim, cocoon, until, share) in cocoons {
            let broken = self
                .world
                .get::<Mob>(cocoon)
                .is_none_or(|m| m.mode == MobMode::Dead);
            if broken {
                if let Some(mut p) = self.world.get_mut::<Player>(victim) {
                    let now = p.last_input_tick + 1;
                    if p.restraint.lock_until > now {
                        p.restraint.lock_until = now.max(p.restraint.lock_from);
                    }
                    p.afflictions.stun_until = tick;
                }
                continue;
            }
            if tick >= until {
                let max = self.world.get::<Player>(victim).map_or(0.0, |p| p.max_hp);
                self.wound_player(victim, victim, max * share, 0.0, false, u8::MAX);
                self.mob_died(cocoon, None);
                continue;
            }
            keep.push((victim, cocoon, until, share));
        }
        if let Some(r) = self.runs[i].as_mut() {
            r.cocoons = keep;
        }
    }

    /// The step's creatures, at the run's level, around their points.
    fn spawn_step(&mut self, i: usize, s: usize, entries: &[SpawnEntry]) {
        let rules = self.rules();
        let Some((copy, difficulty, ref_level, party)) = self.runs[i]
            .as_ref()
            .map(|r| (r.copy, r.difficulty, r.ref_level, r.roster.len()))
        else {
            return;
        };
        let offset = offset_of(copy);
        let diff = rules.dungeons.difficulties[difficulty].clone();
        let pack = self.run_pack(i, s, entries);
        let max_level = rules.progress.max_level;
        // Teeming: a quarter more of the ordinary groups, beside them.
        let teeming = self.runs[i]
            .as_ref()
            .is_some_and(|r| r.affixes.iter().any(|a| a == "teeming"));
        let mut entries: Vec<SpawnEntry> = entries.to_vec();
        if teeming {
            let trash: Vec<SpawnEntry> = entries
                .iter()
                .filter(|e| e.role == "trash")
                .cloned()
                .collect();
            let extra = (trash.len() as f32 * rules.dungeons.affixes.num("teeming", "extra", 0.25))
                .ceil() as usize;
            let offset = offset_of(self.runs[i].as_ref().map_or(0, |r| r.copy));
            for e in trash.into_iter().take(extra) {
                let mut more = e;
                // Beside the group where the floor runs on; on it otherwise
                // (never behind a wall).
                let chest = Vec3::new(0.0, 1.0, 0.0);
                let from = self.settle(v3(more.at) + offset) + chest;
                let beside = self.settle(v3(more.at) + offset + Vec3::new(1.6, 0.0, 1.2)) + chest;
                if self.terrain.line_hit(from, beside).is_none() {
                    more.at = [more.at[0] + 1.6, more.at[1], more.at[2] + 1.2];
                }
                entries.push(more);
            }
        }
        for e in &entries {
            if e.min_difficulty > difficulty {
                continue;
            }
            let Some(species) = self.game.species.iter().position(|x| x.id == e.mob) else {
                eprintln!("[dungeon] unknown creature {}", e.mob);
                continue;
            };
            let level = rules
                .dungeons
                .mob_level(ref_level, difficulty, &e.role, e.lvl, max_level);
            let n = rules.dungeons.group_count(e, difficulty, party);
            let hp_scale = rules.dungeons.hp_scale(difficulty, &e.role, party);
            let forces = rules.dungeons.roles.get(&e.role).map_or(0, |r| r.forces);
            let boss = e.role == "boss" || e.role == "miniboss";
            for k in 0..n {
                // A sunflower spiral around the point.
                let (r, a) = if n > 1 {
                    (
                        e.spread * ((k as f32 + 0.5) / n as f32).sqrt(),
                        k as f32 * 2.399_96,
                    )
                } else {
                    (0.0, 0.0)
                };
                let center = self.settle(v3(e.at) + offset);
                let spot = center + Vec3::new(libm::cosf(a) * r, 0.0, libm::sinf(a) * r);
                // A spot behind a wall from the group's centre is inside or
                // past it: the member stands at the centre instead.
                let chest = Vec3::new(0.0, 1.0, 0.0);
                let at = if r > 0.0
                    && self
                        .terrain
                        .line_hit(center + chest, spot + chest)
                        .is_some()
                {
                    center
                } else {
                    self.settle(spot)
                };
                let entity =
                    self.spawn_run_mob(pack, species, level, at, hp_scale, diff.damage, e, boss);
                let (exp, base_hp, base_attack, base_speed) = self
                    .world
                    .get::<Mob>(entity)
                    .map_or((0, 0.0, 0.0, 0.0), |m| {
                        (m.exp_reward, m.max_hp, m.attack_power, m.move_speed)
                    });
                if let Some(mut m) = self.world.get_mut::<Mob>(entity) {
                    // Kills pay the members in the copy, not the hitters.
                    m.exp_reward = 0;
                    m.windup_scale = diff.telegraph;
                    m.drop_scale = diff.drop
                        * if boss {
                            1.0
                        } else {
                            rules.dungeons.rewards.creature_drop
                        };
                }
                let boss_name = boss
                    .then(|| e.boss_key.as_ref().and_then(|k| rules.mobs.bosses.get(k)))
                    .flatten()
                    .map(|b| b.name.clone());
                if let Some(run) = self.runs[i].as_mut() {
                    run.mobs.push(RunMob {
                        entity,
                        step: s,
                        forces,
                        credited: false,
                        exp,
                        level,
                        boss_name,
                        role: e.role.clone(),
                        base_hp,
                        base_attack,
                        base_speed,
                        stacks: 0,
                        raged: false,
                        pulled_at: None,
                        hatch: e.hatch.as_ref().map(|h| {
                            (
                                self.tick + (h.after_s * SIM_HZ as f32) as u32,
                                h.into.clone(),
                            )
                        }),
                        marks: e.marks.get(&difficulty).cloned().unwrap_or_default(),
                    });
                }
            }
        }
    }

    /// The pack a step's creatures belong to (reused from a closed copy
    /// when one is free).
    fn run_pack(&mut self, i: usize, s: usize, entries: &[SpawnEntry]) -> usize {
        // A step keeps one pack (eggs that hatch, a cocoon join it).
        if let Some(p) = self.runs[i].as_ref().and_then(|r| r.step_pack[s]) {
            return p;
        }
        let rules = self.rules();
        let copy = self.runs[i].as_ref().map_or(0, |r| r.copy);
        let boss_entry = entries
            .iter()
            .find(|e| e.boss_key.is_some() && matches!(e.role.as_str(), "boss" | "miniboss"));
        let boss_setup = boss_entry.map(|e| {
            let template = e
                .template
                .as_ref()
                .and_then(|t| rules.mobs.templates.get(t));
            BossSetup {
                key: e.boss_key.clone().unwrap_or_default(),
                style: template
                    .map(|t| t.style.clone())
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "spider".to_owned()),
                // A run's boss keeps to the run's leash, as in the old
                // dungeon director: its room is gated and a wipe sends it
                // home. The template's arena radius is the open world's
                // (18 m left the Silk Queen resetting while a cocoon held
                // her lone foe at the front of the nest).
                arena_radius: 0.0,
            }
        });
        let species = entries
            .first()
            .and_then(|e| self.game.species.iter().position(|x| x.id == e.mob))
            .unwrap_or(0);
        let first = entries.first().map_or([0.0; 3], |e| e.at);
        let offset = offset_of(copy);
        let pack = Pack {
            kind: PackKind::Dungeon(copy),
            species,
            level: 1,
            count: 0,
            boss: boss_setup.is_some(),
            center: (first[0] + offset.x, first[2] + offset.z),
            half_extent: (0.0, 0.0),
            leash: RUN_LEASH,
            aggressive: true,
            assist_radius: entries
                .iter()
                .filter_map(|e| e.assist)
                .fold(None, |m: Option<f32>, a| Some(m.map_or(a, |m| m.max(a))))
                .unwrap_or(DEFAULT_ASSIST),
            clear_radius: 0.0,
            respawn_ticks: (0, 0),
            boss_setup,
            commander: false,
            world_boss: false,
        };
        let state = super::brain::PackState {
            anchor: v3(first) + offset,
            members: Vec::new(),
            alive: 0,
            respawn_at: None,
            waves_done: 0,
            announced: false,
        };
        let index = if let Some(free) = self.free_packs.pop() {
            self.game.packs[free] = pack;
            self.packs[free] = state;
            self.pack_views[free].clear();
            free
        } else {
            self.game.packs.push(pack);
            self.packs.push(state);
            self.pack_views.push(Vec::new());
            self.game.packs.len() - 1
        };
        if let Some(r) = self.runs[i].as_mut() {
            r.step_pack[s] = Some(index);
        }
        index
    }

    #[allow(clippy::too_many_arguments)]
    fn spawn_run_mob(
        &mut self,
        pack: usize,
        species: usize,
        level: u32,
        at: Vec3,
        hp_scale: f32,
        damage: f32,
        e: &SpawnEntry,
        boss: bool,
    ) -> Entity {
        let rules = self.rules();
        let (hp, power) = self.game.stats_at(species, level);
        let sp = &self.game.species[species];
        let (mut range, mut speed) = (sp.attack_range, sp.move_speed);
        let elite = e.role == "elite";
        let (mut hp, mut power) = if elite {
            (
                hp * rules.mobs.elite.hp_mult,
                power * rules.mobs.elite.attack_mult,
            )
        } else {
            (hp, power)
        };
        let boss_def = e
            .boss_key
            .as_ref()
            .filter(|_| boss)
            .and_then(|k| rules.mobs.bosses.get(k));
        if let (Some(b), Some((bhp, bpower))) = (
            boss_def,
            e.boss_key.as_ref().and_then(|k| self.game.boss_stats(k)),
        ) {
            // Authored at its stat level; the run's level scales it.
            let ratio = if b.stat_level > 0 {
                self.game.strength_at(level) / self.game.strength_at(b.stat_level)
            } else {
                1.0
            };
            hp = bhp * ratio;
            power = bpower * ratio;
            range = b.attack_range;
            speed = b.move_speed;
        }
        hp *= hp_scale * self.dev_dungeon_scale;
        power *= damage * self.dev_dungeon_scale;
        let mob = Mob {
            pack,
            species: species as u16,
            home: at,
            pos: at,
            yaw: (xorshift(&mut self.dice_state) & 0xFFFF) as u16,
            hp,
            max_hp: hp,
            level,
            attack_power: power,
            attack_range: range,
            move_speed: speed,
            elite,
            boss: boss_def.is_some(),
            enraged: false,
            pattern_next: 0,
            exp_reward: 0,
            credit: Vec::new(),
            mode: MobMode::Idle,
            attack_cd: 0.0,
            attack: None,
            attacks_made: 0,
            thrown: Vec::new(),
            hit_at: self.tick,
            unreachable_since: 0,
            next_scan: 0,
            next_think: self.tick,
            died_at: 0,
            rng: xorshift(&mut self.dice_state) | 1,
            state: STATE_IDLE,
            path: Vec::new(),
            path_goal: at,
            replan_at: 0,
            status: super::status::Status::default(),
            drop_scale: 1.0,
            windup_scale: 1.0,
            part_of: None,
            parts: Vec::new(),
            phase: 1,
        };
        let entity = self.world.spawn(mob).id();
        let id = self.new_id(entity);
        self.world.entity_mut(entity).insert(NetId(id));
        self.packs[pack].members.push(entity);
        self.packs[pack].alive += 1;
        let exp = self.world.get::<Mob>(entity).map(|m| self.exp_reward_of(m));
        if let (Some(exp), Some(mut m)) = (exp, self.world.get_mut::<Mob>(entity)) {
            m.exp_reward = exp;
        }
        // A multi-part boss: its parts, at its level and scale.
        let species_id = self.game.species[species].id.clone();
        if let (Some(parts), Some(b)) = (rules.mobs.parts.get(&species_id), boss_def) {
            let ratio = if b.stat_level > 0 {
                self.game.strength_at(level) / self.game.strength_at(b.stat_level)
            } else {
                1.0
            };
            let part_hp =
                b.part_hp * self.game.hp_multiplier * ratio * hp_scale * self.dev_dungeon_scale;
            let part_species = self.game.species.iter().position(|x| x.id == parts.species);
            let mut list = Vec::new();
            for (name, _) in &parts.offsets {
                let Some(ps) = part_species else { break };
                let part = Mob {
                    pack,
                    species: ps as u16,
                    home: at,
                    pos: at,
                    yaw: 0,
                    hp: part_hp,
                    max_hp: part_hp,
                    level,
                    attack_power: 0.0,
                    attack_range: 0.0,
                    move_speed: 0.0,
                    elite: false,
                    boss: false,
                    enraged: false,
                    pattern_next: 0,
                    exp_reward: 0,
                    credit: Vec::new(),
                    mode: MobMode::Idle,
                    attack_cd: 0.0,
                    attack: None,
                    attacks_made: 0,
                    thrown: Vec::new(),
                    hit_at: self.tick,
                    unreachable_since: 0,
                    next_scan: 0,
                    next_think: self.tick,
                    died_at: 0,
                    rng: xorshift(&mut self.dice_state) | 1,
                    state: STATE_IDLE,
                    path: Vec::new(),
                    path_goal: at,
                    replan_at: 0,
                    status: super::status::Status::default(),
                    drop_scale: 0.0,
                    windup_scale: 1.0,
                    part_of: Some(entity),
                    parts: Vec::new(),
                    phase: 1,
                };
                let pe = self.world.spawn(part).id();
                let pid = self.new_id(pe);
                self.world.entity_mut(pe).insert(NetId(pid));
                list.push((pe, name.clone()));
            }
            if let Some(mut m) = self.world.get_mut::<Mob>(entity) {
                if parts.hp_is_sum {
                    m.max_hp = part_hp * list.len() as f32;
                    m.hp = m.max_hp;
                }
                m.parts = list;
            }
            self.follow_body(entity);
        }
        entity
    }

    /// Holds a boss's parts at their bones (the model faces +z; the body's
    /// yaw 0 looks along -z).
    fn follow_body(&mut self, body: Entity) {
        let rules = self.rules();
        let Some((pos, yaw, species, parts)) = self
            .world
            .get::<Mob>(body)
            .map(|m| (m.pos, m.yaw, usize::from(m.species), m.parts.clone()))
        else {
            return;
        };
        let Some(def) = rules.mobs.parts.get(&self.game.species[species].id) else {
            return;
        };
        let turn = f32::from(yaw) * (core::f32::consts::TAU / 65_536.0) + core::f32::consts::PI;
        let (s, c) = (libm::sinf(turn), libm::cosf(turn));
        for (e, name) in parts {
            let Some(o) = def
                .offsets
                .iter()
                .find(|(n, _)| *n == name)
                .map(|(_, o)| *o)
            else {
                continue;
            };
            let at = pos + Vec3::new(o[0] * c + o[2] * s, o[1], -o[0] * s + o[2] * c);
            if let Some(mut m) = self.world.get_mut::<Mob>(e) {
                m.pos = at;
                m.home = at;
                m.yaw = yaw;
            }
        }
    }

    /// Every tick: parts ride their bodies; a summed body's health is its
    /// standing parts'; a body walking home after a wipe has its parts back.
    pub(super) fn follow_parts(&mut self) {
        if !self.instanced {
            return;
        }
        let tick = self.tick;
        let rules = self.rules();
        let bodies: Vec<Entity> = self
            .runs
            .iter()
            .flatten()
            .flat_map(|r| {
                r.mobs
                    .iter()
                    .filter(|m| m.boss_name.is_some())
                    .map(|m| m.entity)
            })
            .filter(|e| {
                self.world
                    .get::<Mob>(*e)
                    .is_some_and(|m| !m.parts.is_empty() && m.mode != MobMode::Dead)
            })
            .collect();
        for body in bodies {
            self.follow_body(body);
            let Some((species, mode, parts)) = self
                .world
                .get::<Mob>(body)
                .map(|m| (usize::from(m.species), m.mode, m.parts.clone()))
            else {
                continue;
            };
            let sum = rules
                .mobs
                .parts
                .get(&self.game.species[species].id)
                .is_some_and(|p| p.hp_is_sum);
            // Home after a wipe: every part stands again.
            if mode == MobMode::Return {
                for (p, _) in &parts {
                    if let Some(mut m) = self.world.get_mut::<Mob>(*p)
                        && m.mode == MobMode::Dead
                    {
                        m.mode = MobMode::Idle;
                        m.state = STATE_IDLE;
                        m.hp = m.max_hp;
                        m.died_at = 0;
                    }
                }
                if let Some(mut m) = self.world.get_mut::<Mob>(body) {
                    m.phase = 1;
                }
            }
            if sum {
                let hp: f32 = parts
                    .iter()
                    .filter_map(|(p, _)| self.world.get::<Mob>(*p))
                    .filter(|m| m.mode != MobMode::Dead)
                    .map(|m| m.hp)
                    .sum();
                if let Some(mut m) = self.world.get_mut::<Mob>(body) {
                    m.hp = hp.max(1.0);
                    // Below a quarter: the third phase.
                    if m.phase >= 2 && m.hp < m.max_hp * 0.25 && m.phase < 3 {
                        m.phase = 3;
                    }
                }
                if tick.is_multiple_of(DIRECTOR_TICKS) {
                    let frenzied = self.world.get::<Mob>(body).is_some_and(|m| m.phase == 3);
                    if frenzied && let Some(i) = self.run_of_mob(body) {
                        let said = self.runs[i]
                            .as_ref()
                            .is_some_and(|r| r.message.contains("frenzied"));
                        if !said {
                            self.say(
                                i,
                                "The Wheelwarden is frenzied - the sluice holds it only briefly!",
                            );
                        }
                    }
                }
            }
        }
    }

    /// The run a creature of this map belongs to.
    fn run_of_mob(&self, mob: Entity) -> Option<usize> {
        self.runs.iter().position(|r| {
            r.as_ref()
                .is_some_and(|r| r.mobs.iter().any(|m| m.entity == mob))
        })
    }

    /// A boss's part fell: its message, the next phase; the last part of a
    /// summed boss takes the body with it, of a shielded one bares it.
    pub(super) fn part_fell(&mut self, part: Entity, body: Entity, killer: Option<Entity>) {
        let rules = self.rules();
        let Some((species, parts)) = self
            .world
            .get::<Mob>(body)
            .map(|m| (usize::from(m.species), m.parts.clone()))
        else {
            return;
        };
        let def = rules
            .mobs
            .parts
            .get(&self.game.species[species].id)
            .cloned()
            .unwrap_or_default();
        let standing = parts
            .iter()
            .filter(|(p, _)| *p != part)
            .filter(|(p, _)| {
                self.world
                    .get::<Mob>(*p)
                    .is_some_and(|m| m.mode != MobMode::Dead)
            })
            .count();
        let name = parts
            .iter()
            .find(|(p, _)| *p == part)
            .map_or("", |(_, n)| n.as_str());
        let Some(i) = self.run_of_mob(body) else {
            return;
        };
        if def.hp_is_sum {
            let side = match name {
                "L" => "left",
                "R" => "right",
                _ => "middle",
            };
            let first = self.world.get_mut::<Mob>(body).is_some_and(|mut m| {
                let first = m.phase < 2;
                m.phase = m.phase.max(2);
                first
            });
            // One line: two said in one tick, the client would see the last.
            if first {
                self.say(
                    i,
                    &format!("The Wheelwarden's {side} plate cracks! Its gears scream!"),
                );
            } else {
                self.say(i, &format!("The Wheelwarden's {side} plate cracks!"));
            }
            if standing == 0 {
                self.mob_died(body, killer);
            }
        } else if standing == 0 {
            self.say(i, "The stems are gone - the Brinebriar's heart is exposed!");
        } else {
            self.say(
                i,
                &format!("A stem cracks apart! {standing} left."),
            );
        }
    }

    /// The sluice wheel: a living player standing by it rings it; a fight
    /// breaks the ringing off; rung through, the guardian sleeps.
    fn chime_tick(&mut self, i: usize) {
        let tick = self.tick;
        // The chime appears with the guardian it lulls.
        if self.runs[i].as_ref().is_some_and(|r| r.chime.is_none()) {
            let rules = self.rules();
            let found = self.runs[i].as_ref().and_then(|r| {
                let def = rules.dungeons.dungeons.get(&r.dungeon)?;
                r.mobs
                    .iter()
                    .filter(|m| m.boss_name.is_some())
                    .find_map(|m| {
                        let step = def.steps.get(m.step)?;
                        let entry = step.spawn.iter().find(|e| e.chime.is_some())?;
                        let scale = entry.chime_scale.get(&r.difficulty).copied().unwrap_or(1.0);
                        Some((m.entity, v3(entry.chime?) + offset_of(r.copy), scale))
                    })
            });
            if let Some((body, at, scale)) = found
                && let Some(r) = self.runs[i].as_mut()
            {
                r.chime = Some(Chime {
                    at,
                    scale,
                    body,
                    ringer: None,
                    combat_at_start: 0,
                    start: 0,
                    end: 0,
                    ready: tick,
                });
            }
        }
        let Some(c) = self.runs[i].as_ref().and_then(|r| r.chime.as_ref()) else {
            return;
        };
        let (at, scale, body, ringer, combat_at_start, end, ready) = (
            c.at,
            c.scale,
            c.body,
            c.ringer,
            c.combat_at_start,
            c.end,
            c.ready,
        );
        let Some((body_mode, phase)) = self.world.get::<Mob>(body).map(|m| (m.mode, m.phase))
        else {
            return;
        };
        if body_mode == MobMode::Dead {
            if let Some(r) = self.runs[i].as_mut() {
                r.chime = None;
            }
            return;
        }
        let near = |p: &Player| {
            p.dead_until == 0
                && planar_distance(p.body.pos, at) <= CHIME_RADIUS
                && (p.body.pos.y - at.y).abs() < 3.0
        };
        match ringer {
            None => {
                if tick < ready {
                    return;
                }
                let copy = self.runs[i].as_ref().map_or(0, |r| r.copy);
                let someone = self.in_copy(copy).into_iter().find_map(|(e, _)| {
                    let p = self.world.get::<Player>(e)?;
                    near(p).then(|| (e, p.last_combat, p.sheet.name.clone()))
                });
                if let Some((e, combat, name)) = someone {
                    let length = (6.0 * scale * SIM_HZ as f32) as u32;
                    if let Some(c) = self.runs[i].as_mut().and_then(|r| r.chime.as_mut()) {
                        c.ringer = Some(e);
                        c.combat_at_start = combat;
                        c.start = tick;
                        c.end = tick + length;
                    }
                    self.say(i, &format!("{name} begins to turn the sluice wheel..."));
                }
            }
            Some(e) => {
                let holding = self
                    .world
                    .get::<Player>(e)
                    .is_some_and(|p| near(p) && p.last_combat == combat_at_start);
                if !holding {
                    if let Some(c) = self.runs[i].as_mut().and_then(|r| r.chime.as_mut()) {
                        c.ringer = None;
                    }
                    self.say(i, "The sluice wheel slips back!");
                    return;
                }
                if tick < end {
                    return;
                }
                let sleep = ((if phase >= 3 { 5.0 } else { 10.0 }) / scale * SIM_HZ as f32) as u32;
                if let Some(mut m) = self.world.get_mut::<Mob>(body) {
                    m.status.stun_until = m.status.stun_until.max(tick + sleep);
                    m.attack = None;
                }
                if let Some(c) = self.runs[i].as_mut().and_then(|r| r.chime.as_mut()) {
                    c.ringer = None;
                    c.ready = tick + (45.0 * scale * SIM_HZ as f32) as u32;
                }
                self.say(
                    i,
                    "Brine floods the Wheelwarden's joints! Its plates take more damage.",
                );
            }
        }
    }

    /// The dungeon's own hazards (the Brine Vaults' breath down the stair):
    /// while their stretch of the run is on and someone stands in the band,
    /// a warned push every so often.
    fn breath_tick(&mut self, i: usize, def: &realm_rules::dungeons::DungeonDef) {
        let tick = self.tick;
        let rules = self.rules();
        let Some((copy, difficulty)) = self.runs[i].as_ref().map(|r| (r.copy, r.difficulty)) else {
            return;
        };
        let mult = rules.dungeons.difficulties[difficulty].hazard_mult;
        let offset = offset_of(copy);
        for (k, h) in def.hazards.iter().enumerate() {
            let step = |id: &str| def.steps.iter().position(|s| s.id == id);
            let on = self.runs[i].as_ref().is_some_and(|r| {
                step(&h.from_step).is_none_or(|s| r.done[s])
                    && step(&h.until_step).is_none_or(|s| !r.done[s])
            });
            if !on {
                continue;
            }
            let center = Vec3::new((h.x.0 + h.x.1) * 0.5, 0.0, (h.z.0 + h.z.1) * 0.5) + offset;
            let half = [(h.x.1 - h.x.0) * 0.5, (h.z.1 - h.z.0) * 0.5];
            // The band's floor is where the one standing in it stands (the
            // hazard has no height of its own).
            let standing = self.in_copy(copy).iter().find_map(|(e, _)| {
                self.world.get::<Player>(*e).and_then(|p| {
                    (p.dead_until == 0
                        && (p.body.pos.x - center.x).abs() <= half[0]
                        && (p.body.pos.z - center.z).abs() <= half[1])
                        .then_some(p.body.pos.y)
                })
            });
            let anyone = standing.is_some();
            let next = self.runs[i].as_ref().map_or(0, |r| r.breath_next[k]);
            let every = (h.every_s * mult * SIM_HZ as f32) as u32;
            if !anyone {
                // The timer starts again when nobody is in the band.
                if let Some(r) = self.runs[i].as_mut() {
                    r.breath_next[k] = tick + every;
                }
                continue;
            }
            if tick < next {
                continue;
            }
            let floor = standing.unwrap_or(center.y);
            let warn = (h.warn_s * SIM_HZ as f32) as u32;
            self.add_mark(
                i,
                "breath",
                Vec3::new(center.x, floor, center.z),
                half[0].max(half[1]),
                (tick + warn, 0),
                0.0,
                half,
                Some((Vec3::new(h.push[0], h.push[1], h.push[2]), h.lift)),
            );
            if let Some(r) = self.runs[i].as_mut() {
                r.breath_next[k] = tick + every;
            }
            if !h.message.is_empty() {
                self.say(i, &h.message);
            }
        }
    }

    /// Shoves a player (a breath, a blast): its body flies, held like a
    /// knock so its owner's prediction takes it as the server's.
    fn push_player(&mut self, player: Entity, push: Vec3, lift: f32) {
        let tick = self.tick;
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        if p.body.mounted || p.dead_until != 0 {
            return;
        }
        let now = p.last_input_tick + 1;
        p.body.shove = Vec3::new(push.x, 0.0, push.z);
        if lift > 0.0 {
            p.body.vel.y = lift;
            p.body.on_floor = false;
        }
        let lock =
            (realm_rules::creatures::shove_lock_ms(push.length(), lift) * SIM_HZ).div_ceil(1000);
        p.afflictions.knock_until = p.afflictions.knock_until.max(tick + lock);
        p.restraint.lock(now, now + lock);
    }

    /// A run's creature fell: its forces, and its experience to every
    /// member in the copy.
    fn run_mob_fell(&mut self, i: usize, k: usize) {
        let rules = self.rules();
        let Some(r) = self.runs[i].as_mut() else {
            return;
        };
        let m = &mut r.mobs[k];
        if m.credited {
            return;
        }
        m.credited = true;
        r.forces = (r.forces + m.forces).min(r.forces_total.max(r.forces + m.forces));
        let (exp, level, copy, difficulty, party) =
            (m.exp, m.level, r.copy, r.difficulty, r.roster.len());
        let (entity, boss, role) = (m.entity, m.boss_name.is_some(), m.role.clone());
        // Death curses: ordinary creatures only (not bosses, eggs, cocoons
        // or what hatched).
        if !boss && role != "object" && role != "hatchling" {
            let at = self.world.get::<Mob>(entity).map(|x| x.pos);
            if let Some(at) = at {
                self.death_curses(i, entity, at);
            }
        }
        let Some(r) = self.runs[i].as_ref() else {
            return;
        };
        let firsts: Vec<(u64, bool)> = r
            .roster
            .iter()
            .map(|x| (x.character, x.first_run))
            .collect();
        if exp == 0 {
            return;
        }
        let kill = rules.dungeons.difficulties[difficulty].kill_exp;
        let together = rules.dungeons.party_exp(party);
        for (entity, _) in self.in_copy(copy) {
            let Some((character, player_level)) = self
                .world
                .get::<Player>(entity)
                .map(|p| (p.sheet.id, p.sheet.level))
            else {
                continue;
            };
            let Some(first) = firsts
                .iter()
                .find(|(c, _)| *c == character)
                .map(|(_, f)| *f)
            else {
                continue;
            };
            let gap = rules.progress.gap(level, player_level).exp;
            let bonus = if first {
                rules.dungeons.rewards.first_run_exp
            } else {
                1.0
            };
            let amount = (f64::from(exp) * f64::from(gap * kill * together * bonus)).round() as u64;
            self.pay(entity, amount, 0);
        }
    }

    /// A run's creature fell at `at`: bursting dead, sticky ground, the
    /// bolster on its neighbours.
    fn death_curses(&mut self, i: usize, dead: Entity, at: Vec3) {
        let rules = self.rules();
        let a = &rules.dungeons.affixes;
        let tick = self.tick;
        let affixes = self.runs[i]
            .as_ref()
            .map(|r| r.affixes.clone())
            .unwrap_or_default();
        if affixes.iter().any(|x| x == "burst") {
            let warn = (a.num("burst", "warn_s", 2.0) * SIM_HZ as f32) as u32;
            self.add_hazard(
                i,
                "burst",
                at,
                a.num("burst", "radius", 4.0),
                tick + warn,
                0,
                a.num("burst", "hp_share", 0.12),
            );
        }
        if affixes.iter().any(|x| x == "sticky") {
            let until = tick + (a.num("sticky", "duration_s", 6.0) * SIM_HZ as f32) as u32;
            self.add_hazard(
                i,
                "sticky",
                at,
                a.num("sticky", "radius", 3.5),
                0,
                until,
                0.0,
            );
        }
        if affixes.iter().any(|x| x == "bolster") {
            let radius = a.num("bolster", "radius", 15.0);
            let max = a.num("bolster", "max_stacks", 5.0) as u8;
            let near: Vec<usize> = self.runs[i].as_ref().map_or(Vec::new(), |r| {
                r.mobs
                    .iter()
                    .enumerate()
                    .filter(|(_, m)| m.entity != dead && m.boss_name.is_none() && m.stacks < max)
                    .filter(|(_, m)| {
                        self.world.get::<Mob>(m.entity).is_some_and(|x| {
                            x.mode != MobMode::Dead && planar_distance(x.pos, at) <= radius
                        })
                    })
                    .map(|(k, _)| k)
                    .collect()
            });
            for k in near {
                if let Some(r) = self.runs[i].as_mut() {
                    r.mobs[k].stacks += 1;
                }
                self.restat(i, k);
            }
        }
    }

    /// A run creature's numbers from its base, bolster stacks and rage.
    fn restat(&mut self, i: usize, k: usize) {
        let rules = self.rules();
        let a = &rules.dungeons.affixes;
        let Some(m) = self.runs[i].as_ref().map(|r| &r.mobs[k]) else {
            return;
        };
        let stacks = f32::from(m.stacks);
        let hp_mult = 1.0 + a.num("bolster", "hp", 0.15) * stacks;
        let mut attack = m.base_attack * (1.0 + a.num("bolster", "damage", 0.15) * stacks);
        let mut speed = m.base_speed;
        if m.raged {
            attack *= a.num("enrage", "damage", 1.5);
            speed *= a.num("enrage", "speed", 1.15);
        }
        let (entity, base_hp) = (m.entity, m.base_hp);
        if let Some(mut x) = self.world.get_mut::<Mob>(entity) {
            let share = if x.max_hp > 0.0 { x.hp / x.max_hp } else { 1.0 };
            x.max_hp = base_hp * hp_mult;
            x.hp = x.max_hp * share;
            x.attack_power = attack;
            x.move_speed = speed;
        }
    }

    /// A curse mark on run `i`'s floor, told to its players.
    #[allow(clippy::too_many_arguments)]
    fn add_hazard(
        &mut self,
        i: usize,
        kind: &str,
        at: Vec3,
        radius: f32,
        release: u32,
        until: u32,
        hp_share: f32,
    ) {
        self.add_mark(
            i,
            kind,
            at,
            radius,
            (release, until),
            hp_share,
            [0.0, 0.0],
            None,
        );
    }

    /// A mark of any shape: a band (`half`), a push instead of damage. Its
    /// shape goes out with it (a client keeps the first word it hears).
    #[allow(clippy::too_many_arguments)]
    fn add_mark(
        &mut self,
        i: usize,
        kind: &str,
        at: Vec3,
        radius: f32,
        (release, until): (u32, u32),
        hp_share: f32,
        half: [f32; 2],
        push: Option<(Vec3, f32)>,
    ) {
        let tick = self.tick;
        self.next_hazard += 1;
        let view = HazardView {
            id: self.next_hazard,
            kind: kind.to_owned(),
            center: [at.x, at.y, at.z],
            radius,
            start_tick: tick,
            release_tick: release,
            until_tick: until,
            hp_share,
            half,
        };
        let Some(copy) = self.runs[i].as_ref().map(|r| r.copy) else {
            return;
        };
        if let Some(r) = self.runs[i].as_mut() {
            r.hazards.push(Hazard {
                view: view.clone(),
                pos: at,
                done: false,
                push,
            });
        }
        for (_, conn) in self.in_copy(copy) {
            self.send_control(
                conn,
                &ServerMsg::Dungeon(Box::new(DungeonMsg::Hazard(view.clone()))),
            );
        }
    }

    /// The timed curses: rage at low health, the chill, the storm; and a
    /// legendary boss's rage (from its pull, again after every reset).
    fn curse_tick(&mut self, i: usize) {
        let rules = self.rules();
        let a = &rules.dungeons.affixes;
        let tick = self.tick;
        let Some((affixes, copy, difficulty)) = self.runs[i]
            .as_ref()
            .map(|r| (r.affixes.clone(), r.copy, r.difficulty))
        else {
            return;
        };
        let diff = &rules.dungeons.difficulties[difficulty];
        let has = |c: &str| affixes.iter().any(|x| x == c);
        let count = self.runs[i].as_ref().map_or(0, |r| r.mobs.len());
        for k in 0..count {
            let Some((entity, boss, raged, pulled)) = self.runs[i].as_ref().map(|r| {
                (
                    r.mobs[k].entity,
                    r.mobs[k].boss_name.is_some(),
                    r.mobs[k].raged,
                    r.mobs[k].pulled_at,
                )
            }) else {
                return;
            };
            let Some((mode, hp, max_hp)) = self
                .world
                .get::<Mob>(entity)
                .map(|m| (m.mode, m.hp, m.max_hp))
            else {
                continue;
            };
            if mode == MobMode::Dead {
                continue;
            }
            if !boss && has("enrage") && !raged && hp < max_hp * a.num("enrage", "below", 0.3) {
                if let Some(r) = self.runs[i].as_mut() {
                    r.mobs[k].raged = true;
                }
                self.restat(i, k);
            }
            let own = self
                .world
                .get::<Mob>(entity)
                .and_then(|m| {
                    let b = self.game.packs[m.pack].boss_setup.as_ref()?;
                    rules.mobs.bosses.get(&b.key).map(|d| d.enrage_s)
                })
                .unwrap_or(0.0);
            let enrage_s = [diff.boss_enrage_s, own]
                .into_iter()
                .filter(|s| *s > 0.0)
                .fold(0.0_f32, |a, s| if a == 0.0 { s } else { a.min(s) });
            if boss && enrage_s > 0.0 {
                let fighting = matches!(mode, MobMode::Chase(_));
                let at_home = matches!(mode, MobMode::Idle | MobMode::Return);
                if fighting && pulled.is_none() {
                    if let Some(r) = self.runs[i].as_mut() {
                        r.mobs[k].pulled_at = Some(tick);
                    }
                } else if at_home && pulled.is_some() {
                    if let Some(r) = self.runs[i].as_mut() {
                        r.mobs[k].pulled_at = None;
                    }
                    if let Some(mut m) = self.world.get_mut::<Mob>(entity) {
                        m.enraged = false;
                    }
                } else if let Some(since) = pulled
                    && tick >= since + (enrage_s * SIM_HZ as f32) as u32
                    && let Some(mut m) = self.world.get_mut::<Mob>(entity)
                    && !m.enraged
                {
                    m.enraged = true;
                    self.say(
                        i,
                        "The guardian of this place flies into a rage - finish it now!",
                    );
                }
            }
        }
        let inside = self.in_copy(copy);
        let living: Vec<Entity> = inside
            .iter()
            .map(|(e, _)| *e)
            .filter(|e| {
                self.world
                    .get::<Player>(*e)
                    .is_some_and(|p| p.dead_until == 0)
            })
            .collect();
        // The chill and the storm wait while there is nobody to strike.
        let next = |every: f32| tick + (every * diff.hazard_mult * SIM_HZ as f32) as u32;
        if has("chill") {
            if living.is_empty() {
                if let Some(r) = self.runs[i].as_mut() {
                    r.chill_next = r.chill_next.max(tick);
                }
            } else if self.runs[i].as_ref().is_some_and(|r| tick >= r.chill_next) {
                let ticks = (a.num("chill", "despair_s", 6.0) * SIM_HZ as f32) as u32;
                for e in &living {
                    if let Some(mut p) = self.world.get_mut::<Player>(*e) {
                        p.afflictions.despair_until = p.afflictions.despair_until.max(tick + ticks);
                    }
                }
                if let Some(r) = self.runs[i].as_mut() {
                    r.chill_next = next(a.num("chill", "every_s", 45.0));
                }
                self.say(
                    i,
                    "A mist chill sweeps the halls - nobody recovers for a while.",
                );
            }
        }
        if has("storm") {
            let fighting = self.runs[i].as_ref().is_some_and(|r| {
                r.mobs.iter().any(|m| {
                    self.world
                        .get::<Mob>(m.entity)
                        .is_some_and(|x| matches!(x.mode, MobMode::Chase(_)))
                })
            });
            if !fighting || living.is_empty() {
                if let Some(r) = self.runs[i].as_mut() {
                    r.storm_next = r.storm_next.max(tick);
                }
            } else if self.runs[i].as_ref().is_some_and(|r| tick >= r.storm_next) {
                let pick = (xorshift(&mut self.dice_state) as usize) % living.len();
                let at = self.world.get::<Player>(living[pick]).map(|p| p.body.pos);
                if let Some(at) = at {
                    let warn = (a.num("storm", "warn_s", 1.2) * SIM_HZ as f32) as u32;
                    self.add_hazard(
                        i,
                        "storm",
                        at,
                        a.num("storm", "radius", 3.5),
                        tick + warn,
                        0,
                        a.num("storm", "hp_share", 0.15),
                    );
                }
                if let Some(r) = self.runs[i].as_mut() {
                    r.storm_next = next(a.num("storm", "every_s", 12.0));
                }
            }
        }
    }

    /// Curse marks go off and hold, every tick: rings strike at their
    /// release, sticky patches and webs slow, venom pools bite each second.
    pub(super) fn tick_hazards(&mut self) {
        if !self.instanced {
            return;
        }
        let tick = self.tick;
        for i in 0..self.runs.len() {
            let Some(copy) = self.runs[i].as_ref().map(|r| r.copy) else {
                continue;
            };
            #[allow(clippy::type_complexity)]
            let marks: Vec<(
                usize,
                String,
                Vec3,
                f32,
                u32,
                u32,
                f32,
                [f32; 2],
                Option<(Vec3, f32)>,
            )> = self.runs[i]
                .as_ref()
                .map(|r| {
                    r.hazards
                        .iter()
                        .enumerate()
                        .filter(|(_, h)| !h.done)
                        .map(|(k, h)| {
                            (
                                k,
                                h.view.kind.clone(),
                                h.pos,
                                h.view.radius,
                                h.view.release_tick,
                                h.view.until_tick,
                                h.view.hp_share,
                                h.view.half,
                                h.push,
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            if marks.is_empty() {
                continue;
            }
            let players: Vec<(Entity, Vec3, f32)> = self
                .in_copy(copy)
                .into_iter()
                .filter_map(|(e, _)| {
                    let p = self.world.get::<Player>(e)?;
                    (p.dead_until == 0).then_some((e, p.body.pos, p.max_hp))
                })
                .collect();
            for (k, kind, at, radius, release, until, share, half, push) in marks {
                let band = half != [0.0, 0.0];
                let inside: Vec<(Entity, f32)> = players
                    .iter()
                    .filter(|(_, p, _)| {
                        let within = if band {
                            (p.x - at.x).abs() <= half[0] && (p.z - at.z).abs() <= half[1]
                        } else {
                            planar_distance(*p, at) <= radius
                        };
                        within && (p.y - at.y).abs() < 4.0
                    })
                    .map(|(e, _, max)| (*e, *max))
                    .collect();
                if let Some((dir, lift)) = push {
                    if tick < release {
                        continue;
                    }
                    for (e, _) in &inside {
                        self.push_player(*e, dir, lift);
                    }
                    if let Some(r) = self.runs[i].as_mut() {
                        r.hazards[k].done = true;
                    }
                    continue;
                }
                let over = match kind.as_str() {
                    "burst" | "storm" => {
                        if tick < release {
                            continue;
                        }
                        for (e, max) in &inside {
                            self.wound_player(*e, *e, max * share, 0.0, false, u8::MAX);
                        }
                        true
                    }
                    _ => {
                        let web = kind == "sticky" || (kind == "pool" && share <= 0.0);
                        if web && tick.is_multiple_of(9) {
                            for (e, _) in &inside {
                                if let Some(mut p) = self.world.get_mut::<Player>(*e) {
                                    let next = p.last_input_tick + 1;
                                    p.restraint.web(next, next + 18, 50);
                                }
                            }
                        }
                        if !web && share > 0.0 && tick.is_multiple_of(SIM_HZ) {
                            for (e, max) in &inside {
                                self.wound_player(*e, *e, max * share, 0.0, false, u8::MAX);
                            }
                        }
                        tick >= until
                    }
                };
                if over && let Some(r) = self.runs[i].as_mut() {
                    r.hazards[k].done = true;
                }
            }
            if let Some(r) = self.runs[i].as_mut() {
                r.hazards
                    .retain(|h| !h.done || h.view.until_tick + 60 > tick);
            }
        }
    }

    /// An elite's blow under the bleeding curse: the victim bleeds.
    pub(super) fn curse_bleed(&mut self, mob: Entity, player: Entity) {
        if !self.instanced {
            return;
        }
        let Some((pos, elite)) = self.world.get::<Mob>(mob).map(|m| (m.pos, m.elite)) else {
            return;
        };
        let Some(i) = self.run_index(self.copy_of(pos)) else {
            return;
        };
        // Elites under the bleeding curse, and creatures the run marked
        // (the Silk Queen on Legendary).
        let marked = self.runs[i].as_ref().is_some_and(|r| {
            r.mobs
                .iter()
                .any(|m| m.entity == mob && m.marks.iter().any(|x| x == "curse_bleed"))
        });
        let cursed = elite
            && self.runs[i]
                .as_ref()
                .is_some_and(|r| r.affixes.iter().any(|a| a == "bleed"));
        if !marked && !cursed {
            return;
        }
        let rules = self.rules();
        let a = &rules.dungeons.affixes;
        let tick = self.tick;
        let interval = (a.num("bleed", "interval_ms", 1000.0) * SIM_HZ as f32 / 1000.0) as u32;
        let ticks = a.num("bleed", "ticks", 6.0) as u32;
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        if p.dead_until != 0 {
            return;
        }
        let damage = p.max_hp * a.num("bleed", "hp_share", 0.02);
        p.afflictions.bleed = Some(super::afflict::Venom {
            until: tick + interval * ticks,
            next: tick + interval,
            interval,
            damage,
            source: mob,
        });
        if !self.poisoned.contains(&player) {
            self.poisoned.push(player);
        }
    }

    /// A player fell: a death on its run's clock and lives.
    pub(super) fn run_player_died(&mut self, player: Entity) {
        let Some(pos) = self.world.get::<Player>(player).map(|p| p.body.pos) else {
            return;
        };
        let Some(i) = self.run_index(self.copy_of(pos)) else {
            return;
        };
        let rules = self.rules();
        let Some(r) = self.runs[i].as_mut() else {
            return;
        };
        if r.phase != 2 {
            return;
        }
        r.deaths += 1;
        if rules.dungeons.difficulties[r.difficulty].lives >= 0 && r.lives_left > 0 {
            r.lives_left -= 1;
            if r.lives_left == 0 {
                r.broken = true;
                r.message = "The party's lives are spent - no medal this run.".to_owned();
            }
        }
    }

    /// A boss still standing with nobody past its line: its closed gates
    /// open again until someone crosses it.
    fn wipe_lock(&mut self, i: usize, def: &realm_rules::dungeons::DungeonDef) {
        for (s, step) in def.steps.iter().enumerate() {
            let Trigger::Area(z) = step.on else { continue };
            if step.close.is_empty() || !self.runs[i].as_ref().is_some_and(|r| r.done[s]) {
                continue;
            }
            let boss_alive = self.runs[i].as_ref().is_some_and(|r| {
                r.mobs
                    .iter()
                    .filter(|m| m.step == s && m.boss_name.is_some())
                    .any(|m| {
                        self.world
                            .get::<Mob>(m.entity)
                            .is_some_and(|x| x.mode != MobMode::Dead)
                    })
            });
            if !boss_alive {
                continue;
            }
            let copy = self.runs[i].as_ref().map_or(0, |r| r.copy);
            let offset = offset_of(copy);
            let past = self.in_copy(copy).iter().any(|(e, _)| {
                self.world
                    .get::<Player>(*e)
                    .is_some_and(|p| p.dead_until == 0 && p.body.pos.z - offset.z < z)
            });
            let unlocked = self.runs[i]
                .as_ref()
                .is_some_and(|r| r.unlocked.contains(&s));
            if !past && !unlocked {
                for g in &step.close {
                    self.set_gate(i, g, true);
                }
                if let Some(r) = self.runs[i].as_mut() {
                    r.unlocked.push(s);
                }
                self.say(i, "The way back is open. Regroup and try again.");
            } else if past && unlocked {
                for g in &step.close {
                    self.set_gate(i, g, false);
                }
                if let Some(r) = self.runs[i].as_mut() {
                    r.unlocked.retain(|x| *x != s);
                }
                self.say(i, &step.message);
            }
        }
    }

    /// The run's clock ran out: every gate opens; the chest only if every
    /// boss fell; no clear is recorded.
    fn time_up(&mut self, i: usize, def: &realm_rules::dungeons::DungeonDef) {
        let gates: Vec<String> = def
            .steps
            .iter()
            .flat_map(|s| s.open.iter().chain(&s.close).cloned())
            .collect();
        for g in gates {
            self.set_gate(i, &g, true);
        }
        let bosses_down = self.runs[i].as_ref().is_some_and(|r| {
            r.mobs.iter().filter(|m| m.boss_name.is_some()).all(|m| {
                self.world
                    .get::<Mob>(m.entity)
                    .is_none_or(|x| x.mode == MobMode::Dead)
            })
        });
        self.say(
            i,
            if bosses_down {
                "Time is up - the guardians fell, but not every creature did."
            } else {
                "Time is up - the run is over."
            },
        );
        let chest = def
            .steps
            .iter()
            .find(|s| s.complete)
            .and_then(|s| s.chest.as_ref())
            .map(|c| c.1);
        self.finish(i, def, true, if bosses_down { chest } else { None });
    }

    /// The run is over: its result, records and rewards.
    fn finish(
        &mut self,
        i: usize,
        def: &realm_rules::dungeons::DungeonDef,
        timeout: bool,
        chest_at: Option<[f32; 3]>,
    ) {
        let rules = self.rules();
        let tick = self.tick;
        self.credit_forces(i);
        let Some(r) = self.runs[i].as_mut() else {
            return;
        };
        if r.phase == 3 {
            return;
        }
        r.phase = 3;
        r.complete = true;
        r.end_tick = tick;
        let diff = rules.dungeons.difficulties[r.difficulty].clone();
        let par = def.par_s * diff.par_mult;
        let elapsed = (tick.saturating_sub(r.start_tick)) as f32 / SIM_HZ as f32
            + f32::from(r.deaths) * diff.death_penalty_s;
        let full = r.forces >= r.forces_total;
        let rank = if timeout {
            -1
        } else {
            rules.dungeons.medal(elapsed, par, full, r.broken)
        };
        let clear = (r.forces * 1000)
            .checked_div(r.forces_total)
            .map_or(1000, |c| c.min(1000) as u16);
        r.result = Some(RunResult {
            rank,
            time_ms: (elapsed * 1000.0) as u32,
            clear,
            deaths: r.deaths,
            timeout,
        });
        println!(
            "[dungeon] copy {} of {} over: rank {rank}, {elapsed:.0} s of par {par:.0}, clear {clear}/1000, deaths {}{}",
            r.copy,
            r.dungeon,
            r.deaths,
            if timeout { ", timed out" } else { "" }
        );
        // The way out opens behind the chest.
        if let Some(step) = def.steps.iter().find(|s| s.complete) {
            for g in step.open.clone() {
                self.set_gate(i, &g, true);
            }
        }
        if let Some(at) = chest_at {
            self.pay_run(i, def, rank, timeout, at);
        }
        // A full clear goes on the week's board.
        if !timeout && rank >= RANK_CLEAR {
            self.board_run(i, def);
        }
        // Legendary gold: the realm hears of it.
        let legendary = self.runs[i]
            .as_ref()
            .is_some_and(|r| DIFFICULTIES.get(r.difficulty) == Some(&"legendary"));
        if !timeout && legendary && rank == dungeons::RANK_GOLD {
            let copy = self.runs[i].as_ref().map_or(0, |r| r.copy);
            let names: Vec<String> = self
                .in_copy(copy)
                .into_iter()
                .filter_map(|(e, _)| self.world.get::<Player>(e).map(|p| p.sheet.name.clone()))
                .collect();
            self.notice(
                None,
                "dungeon_legend",
                def.display.clone(),
                names.join(", "),
                (0, 0),
            );
        }
        self.publish(i);
        self.runs_changed();
    }

    /// Records the run for every member in the copy and pays the rewarded.
    fn pay_run(
        &mut self,
        i: usize,
        def: &realm_rules::dungeons::DungeonDef,
        rank: i8,
        timeout: bool,
        chest_local: [f32; 3],
    ) {
        let rules = self.rules();
        let Some(r) = self.runs[i].as_mut() else {
            return;
        };
        if r.paid {
            return;
        }
        r.paid = true;
        let (copy, difficulty, ref_level, party) =
            (r.copy, r.difficulty, r.ref_level, r.roster.len());
        let roster: Vec<(u64, bool, bool)> = r
            .roster
            .iter()
            .map(|m| (m.character, m.rewarded, m.first_run))
            .collect();
        let time_ms = r.result.as_ref().map_or(0, |x| x.time_ms);
        let diff = rules.dungeons.difficulties[difficulty].clone();
        let rw = rules.dungeons.rewards.clone();
        let medal = rank.max(0) as usize;
        let day = dungeons::reward_day(super::now_unix());
        let chest_at = self.settle(v3(chest_local) + offset_of(copy));
        let together = rules.dungeons.party_exp(party);
        for (entity, conn) in self.in_copy(copy) {
            let Some(character) = self.world.get::<Player>(entity).map(|p| p.sheet.id) else {
                continue;
            };
            let Some(&(_, rewarded, first)) = roster.iter().find(|m| m.0 == character) else {
                continue;
            };
            // The record: a clear (with its medal) only without a timeout.
            let before: Vec<bool> = (0..DIFFICULTIES.len())
                .map(|d| {
                    self.world
                        .get::<Player>(entity)
                        .is_some_and(|p| rules.dungeons.unlocked(&p.sheet, &def.id, d))
                })
                .collect();
            let mut title = String::new();
            if let Some(mut p) = self.world.get_mut::<Player>(entity) {
                let cleared = (!timeout && rank >= RANK_CLEAR).then_some(rank);
                p.sheet
                    .dungeons
                    .record(&def.id, difficulty, cleared, time_ms, rewarded, day);
                if let (Some((id, name)), false) = (&def.title, timeout)
                    && !p.sheet.dungeons.titles.contains(id)
                {
                    p.sheet.dungeons.titles.push(id.clone());
                    title.clone_from(name);
                }
                p.sheet.revision += 1;
                p.dirty_since.get_or_insert(self.tick);
            }
            let unlocked: Vec<u8> = (0..DIFFICULTIES.len())
                .filter(|d| {
                    !before[*d]
                        && self
                            .world
                            .get::<Player>(entity)
                            .is_some_and(|p| rules.dungeons.unlocked(&p.sheet, &def.id, *d))
                })
                .map(|d| d as u8)
                .collect();
            let (mut exp, mut oril, mut items) = (0_u64, 0_u64, Vec::new());
            if rewarded {
                let Some(level) = self.world.get::<Player>(entity).map(|p| p.sheet.level) else {
                    continue;
                };
                let gap = rules.progress.gap(u32::from(ref_level), level).exp.min(1.0);
                let first = if first { rw.first_run_exp } else { 1.0 };
                exp = (rules.progress.exp_threshold(level) as f64
                    * f64::from(
                        diff.exp_budget
                            * rw.completion_share
                            * gap
                            * together
                            * first
                            * rw.medal_exp[medal],
                    ))
                .round() as u64;
                let mut dice = ServerDice(xorshift(&mut self.dice_state) | 1);
                let (lo, hi) = rw.oril_per_level;
                let per = lo + (unit(&mut dice.0) * (hi.saturating_sub(lo) + 1) as f32) as u32;
                oril = (f64::from(per)
                    * f64::from(u32::from(level.min(ref_level)))
                    * f64::from(diff.gold * (1.0 + rw.medal_gold[medal])))
                .round() as u64;
                let chest = self.run_chest(def, &diff, difficulty, ref_level, medal, &mut dice);
                self.dice_state = dice.0;
                oril += chest.oril;
                items = chest.items;
                self.pay(entity, exp, oril);
                if !items.is_empty() {
                    self.drop_owned_chest(chest_at, items.clone(), character);
                }
            }
            let map = self.game.map.clone();
            self.quest_event(entity, "dungeon", &def.id, false);
            let _ = map;
            self.send_control(
                conn,
                &ServerMsg::Dungeon(Box::new(DungeonMsg::Rewards {
                    helper: !rewarded,
                    rank,
                    exp,
                    oril,
                    items: items
                        .iter()
                        .map(|it| (it.id.clone(), it.amount, it.bonuses.len() as u8))
                        .collect(),
                    unlocked,
                    title,
                })),
            );
            self.send_sheet(conn);
        }
    }

    /// Sends a full clear to the coordinator's weekly board.
    fn board_run(&mut self, i: usize, def: &realm_rules::dungeons::DungeonDef) {
        let Some(r) = self.runs[i].as_ref() else {
            return;
        };
        let Some(result) = r.result.clone() else {
            return;
        };
        let roster: Vec<u64> = r.roster.iter().map(|m| m.character).collect();
        let difficulty = r.difficulty as u8;
        let party: Vec<(u64, String, u16)> = roster
            .iter()
            .filter_map(|c| {
                let (_, e) = self.player_of(*c)?;
                let p = self.world.get::<Player>(e)?;
                Some((*c, p.sheet.name.clone(), p.sheet.level))
            })
            .collect();
        self.coord_send(MapMsg::RunRecord {
            dungeon: def.id.clone(),
            difficulty,
            week: dungeons::curse_week(super::now_unix()),
            run: realm_proto::coord::BoardRun {
                ms: result.time_ms,
                rank: result.rank,
                deaths: result.deaths,
                party: party.iter().map(|(_, n, l)| (n.clone(), *l)).collect(),
            },
            characters: party.iter().map(|(c, _, _)| *c).collect(),
        });
    }

    /// A run took first place on its board: the title for its party on
    /// this map, and the realm hears of it.
    pub(super) fn record_set(
        &mut self,
        dungeon: &str,
        difficulty: u8,
        ms: u32,
        names: &[String],
        characters: &[u64],
    ) {
        let tick = self.tick;
        for c in characters {
            let Some((conn, e)) = self.player_of(*c) else {
                continue;
            };
            let earned = self.world.get_mut::<Player>(e).is_some_and(|mut p| {
                if p.sheet
                    .dungeons
                    .titles
                    .iter()
                    .any(|t| t == "dungeon_record")
                {
                    return false;
                }
                p.sheet.dungeons.titles.push("dungeon_record".to_owned());
                p.sheet.revision += 1;
                p.dirty_since.get_or_insert(tick);
                true
            });
            if earned {
                self.send_sheet(conn);
            }
        }
        let rules = self.rules();
        let display = rules
            .dungeons
            .dungeons
            .get(dungeon)
            .map_or(dungeon.to_owned(), |d| d.display.clone());
        let diff = rules
            .dungeons
            .difficulties
            .get(usize::from(difficulty))
            .map_or(String::new(), |d| d.display.clone());
        let text = format!(
            "{} set this week's record in {display} ({diff}): {}:{:02}!",
            names.join(", "),
            ms / 60_000,
            (ms / 1000) % 60
        );
        let conns: Vec<ConnId> = self.clients.keys().copied().collect();
        for conn in conns {
            self.send_control(
                conn,
                &ServerMsg::Chat {
                    channel: realm_proto::coord::CHANNEL_SYSTEM,
                    from: String::new(),
                    text: text.clone(),
                    speaker: 0,
                },
            );
        }
    }

    /// `ClientMsg::DungeonGuide`: the player's records, the week's boards.
    pub(super) fn dungeon_guide(&mut self, conn: ConnId, entity: Entity) {
        let rules = self.rules();
        let day = dungeons::reward_day(super::now_unix());
        let week = dungeons::curse_week(super::now_unix());
        let Some(p) = self.world.get::<Player>(entity) else {
            return;
        };
        let mut records = Vec::new();
        for def in rules.dungeons.dungeons.values() {
            for d in 0..DIFFICULTIES.len() {
                records.push((
                    def.id.clone(),
                    d as u8,
                    p.sheet.dungeons.rank(&def.id, d).unwrap_or(-1),
                    p.sheet.dungeons.best_ms(&def.id, d),
                    rules.dungeons.rights_left(&p.sheet, &def.id, d, day),
                ));
            }
        }
        let titles = p.sheet.dungeons.titles.clone();
        let boards = self
            .boards
            .iter()
            .filter(|b| b.week == week)
            .cloned()
            .collect();
        self.send_control(
            conn,
            &ServerMsg::Dungeon(Box::new(DungeonMsg::Guide {
                week,
                affixes: rules.dungeons.affixes.of_week(week),
                records,
                boards,
                titles,
            })),
        );
    }

    /// Whether `pos` stands near a gate into a dungeon on this map (the
    /// seal shop's counter).
    pub(super) fn near_dungeon_gate(&self, pos: Vec3) -> bool {
        let rules = self.rules();
        let reach = rules.dungeons.group.gather_radius;
        rules.travel.portals.iter().any(|p| {
            p.map == self.game.map
                && rules
                    .travel
                    .maps
                    .get(&p.to_map)
                    .is_some_and(|m| m.instanced)
                && planar_distance(pos, v3(p.center)) <= reach
                && (pos.y - p.center[1]).abs() <= VERTICAL_GATHER
        })
    }

    /// The final chest's contents for one member.
    fn run_chest(
        &self,
        def: &realm_rules::dungeons::DungeonDef,
        diff: &realm_rules::dungeons::Difficulty,
        difficulty: usize,
        ref_level: u16,
        medal: usize,
        dice: &mut ServerDice,
    ) -> realm_rules::loot::Loot {
        let rules = self.rules();
        let rw = &rules.dungeons.rewards;
        let table = def
            .steps
            .iter()
            .find_map(|s| s.chest.as_ref().map(|c| c.0.clone()))
            .unwrap_or_default();
        let mut loot = rules.roll_loot(
            &realm_rules::loot::Kill {
                table: &table,
                level: u32::from(ref_level),
                elite: false,
                boss: true,
                stone: false,
                drop_factor: diff.drop,
            },
            dice,
        );
        let level = if realm_rules::Dice::unit(dice) < diff.tier_up {
            u32::from(ref_level) + 15
        } else {
            u32::from(ref_level)
        };
        let (lo, hi) = diff.bonus_count;
        let count =
            lo + (realm_rules::Dice::unit(dice) * f32::from(hi.saturating_sub(lo) + 1)) as u8;
        if let Some(piece) = rules.dungeon_gear(level, count.min(hi), dice) {
            loot.items.push(piece);
        }
        if realm_rules::Dice::unit(dice) < rw.medal_item[medal]
            && let Some(piece) = rules.dungeon_gear(level, (hi + 1).min(4), dice)
        {
            loot.items.push(piece);
        }
        let seals = diff.seals + rw.medal_seals[medal];
        if seals > 0 {
            loot.items.push(rules.new_item("dungeon_seal", seals));
        }
        if let Some(n) = rw.key_drop.get(&difficulty)
            && !def.key.is_empty()
        {
            loot.items.push(rules.new_item(&def.key, *n));
        }
        loot
    }

    /// A run's copy closes: its creatures go, its packs are free again.
    fn close_copy(&mut self, i: usize) {
        let Some(run) = self.runs[i].take() else {
            return;
        };
        for m in &run.mobs {
            let parts: Vec<Entity> = self
                .world
                .get::<Mob>(m.entity)
                .map(|x| x.parts.iter().map(|(p, _)| *p).collect())
                .unwrap_or_default();
            for p in parts {
                if self.world.get::<Mob>(p).is_some() {
                    self.despawn(p);
                }
            }
            if self.world.get::<Mob>(m.entity).is_some() {
                self.despawn(m.entity);
            }
        }
        for p in run.step_pack.iter().flatten() {
            self.packs[*p].members.clear();
            self.packs[*p].alive = 0;
            self.free_packs.push(*p);
        }
        self.gates.reset(run.copy);
        println!("[dungeon] copy {} of {} closed", run.copy, run.dungeon);
        self.runs_changed();
    }

    // ------------------------------------------------------------ the gate

    /// Why `member` may not go in now ("" when nothing).
    fn member_problem(&self, member: Entity, at: &Gather, dungeon_map: &str) -> &'static str {
        let tick = self.tick;
        let Some(p) = self.world.get::<Player>(member) else {
            return "not_gathered";
        };
        let gather = self.rules().dungeons.group.gather_radius;
        let away = match at {
            Gather::Gate(portal) => {
                let center = v3(portal.center);
                planar_distance(p.body.pos, center) > gather
                    || (p.body.pos.y - center.y).abs() > VERTICAL_GATHER
            }
            Gather::Copy(copy) => self.copy_of(p.body.pos) != *copy,
        };
        if p.dead_until != 0 {
            "dead"
        } else if p.trip.is_some() {
            "transfer_pending"
        } else if p.body.mounted || p.restraint.riding(p.last_input_tick + 1) {
            "mounted"
        } else if self.duels_has(member) {
            "in_duel"
        } else if p.last_combat != 0 && tick < p.last_combat + GATE_COMBAT_TICKS {
            "in_combat"
        } else if away {
            "not_gathered"
        } else if matches!(at, Gather::Gate(_))
            && self
                .dungeon_runs
                .iter()
                .any(|r| r.roster.contains(&p.sheet.id) && r.inside > 0 && r.map != dungeon_map)
        {
            "in_run"
        } else {
            ""
        }
    }

    /// The party a gate sees for `asker`: its leader and members on this
    /// map (the asker alone without a party).
    fn gate_party(&self, asker: Entity) -> (u64, Vec<(u64, Option<Entity>)>) {
        let Some(p) = self.world.get::<Player>(asker) else {
            return (0, Vec::new());
        };
        if p.party.party == 0 {
            return (p.sheet.id, vec![(p.sheet.id, Some(asker))]);
        }
        let members = p
            .party
            .members
            .iter()
            .map(|m| (m.character, self.player_of(m.character).map(|(_, e)| e)))
            .collect();
        (p.party.leader, members)
    }

    /// `ClientMsg::DungeonInfo`.
    pub(super) fn dungeon_info(&mut self, conn: ConnId, entity: Entity, portal: &str) {
        let rules = self.rules();
        let Some((portal, def)) = self.gate_of(portal) else {
            return;
        };
        let day = dungeons::reward_day(super::now_unix());
        let (leader, members) = self.gate_party(entity);
        let mut out = Vec::new();
        for (character, e) in &members {
            let Some(e) = e else {
                out.push(GateMember {
                    character: *character,
                    status: "not_gathered".to_owned(),
                    ..GateMember::default()
                });
                continue;
            };
            let Some(p) = self.world.get::<Player>(*e) else {
                continue;
            };
            let status = self.member_problem(*e, &Gather::Gate(portal.clone()), &def.map);
            out.push(GateMember {
                character: *character,
                name: p.sheet.name.clone(),
                level: p.sheet.level,
                status: status.to_owned(),
                unlocked: (0..DIFFICULTIES.len())
                    .map(|d| rules.dungeons.unlocked(&p.sheet, &def.id, d))
                    .collect(),
                rights: (0..DIFFICULTIES.len())
                    .map(|d| rules.dungeons.rights_left(&p.sheet, &def.id, d, day))
                    .collect(),
                best_ms: (0..DIFFICULTIES.len())
                    .map(|d| p.sheet.dungeons.best_ms(&def.id, d))
                    .collect(),
            });
        }
        let leader_name = members
            .iter()
            .find(|(c, _)| *c == leader)
            .and_then(|(_, e)| e.and_then(|e| self.world.get::<Player>(e)))
            .map(|p| p.sheet.name.clone())
            .unwrap_or_default();
        let me = self.world.get::<Player>(entity).map_or(0, |p| p.sheet.id);
        let active = self
            .dungeon_runs
            .iter()
            .find(|r| r.map == def.map && r.roster.contains(&me))
            .cloned();
        let check = self
            .ready_checks
            .iter()
            .find(|c| c.roster.contains(&me))
            .map(|c| self.ready_view(c));
        self.send_control(
            conn,
            &ServerMsg::Dungeon(Box::new(DungeonMsg::Info {
                dungeon: def.id.clone(),
                portal: portal.id.clone(),
                leader: leader_name,
                members: out,
                active,
                check,
                affixes: rules
                    .dungeons
                    .affixes
                    .of_week(dungeons::curse_week(super::now_unix())),
            })),
        );
    }

    fn ready_view(&self, c: &Check) -> ReadyView {
        let name = |ch: u64| {
            self.player_of(ch)
                .and_then(|(_, e)| self.world.get::<Player>(e))
                .map(|p| (p.sheet.name.clone(), p.sheet.level))
                .unwrap_or_default()
        };
        ReadyView {
            id: c.id,
            dungeon: c.dungeon.clone(),
            difficulty: c.difficulty as u8,
            leader: name(c.leader).0,
            members: c
                .roster
                .iter()
                .map(|ch| {
                    let (n, l) = name(*ch);
                    (n, l, c.ready.contains(ch))
                })
                .collect(),
            ends_tick: c.ends,
        }
    }

    fn gate_refuse(&mut self, conn: ConnId, reason: &str, who: &str, value: i32) {
        self.send_control(
            conn,
            &ServerMsg::Dungeon(Box::new(DungeonMsg::Refused {
                reason: reason.to_owned(),
                who: who.to_owned(),
                value,
            })),
        );
    }

    /// The gate's rules for the party of `leader` at `difficulty`: its
    /// roster, or a refusal (reason, who, value).
    fn gate_check(
        &self,
        leader_entity: Entity,
        at: &Gather,
        def: &realm_rules::dungeons::DungeonDef,
        difficulty: usize,
    ) -> Result<Vec<u64>, (&'static str, String, i32)> {
        let rules = self.rules();
        let diff = &rules.dungeons.difficulties[difficulty];
        let me = self
            .world
            .get::<Player>(leader_entity)
            .map_or(0, |p| p.sheet.id);
        let (leader, members) = self.gate_party(leader_entity);
        if leader != me {
            return Err(("not_leader", String::new(), 0));
        }
        if members.len() < usize::from(diff.min_party) {
            return Err(("party_size", String::new(), i32::from(diff.min_party)));
        }
        if members.len() > rules.dungeons.group.max_party {
            return Err((
                "party_size",
                String::new(),
                rules.dungeons.group.max_party as i32,
            ));
        }
        let need = def.level_min + diff.min_level_add;
        let mut levels = Vec::new();
        for (character, e) in &members {
            let Some(e) = e else {
                return Err(("not_gathered", character.to_string(), 0));
            };
            let Some(p) = self.world.get::<Player>(*e) else {
                return Err(("not_gathered", character.to_string(), 0));
            };
            let name = p.sheet.name.clone();
            let problem = self.member_problem(*e, at, &def.map);
            if !problem.is_empty() {
                return Err((problem, name, 0));
            }
            if p.sheet.level < need {
                return Err(("level_too_low", name, i32::from(need)));
            }
            if !rules.dungeons.unlocked(&p.sheet, &def.id, difficulty) {
                return Err(("difficulty_locked", name, 0));
            }
            levels.push(p.sheet.level);
        }
        let spread = levels.iter().max().unwrap_or(&0) - levels.iter().min().unwrap_or(&0);
        if spread > rules.dungeons.group.max_level_spread {
            return Err(("level_spread", String::new(), i32::from(spread)));
        }
        if diff.keys > 0 && !def.key.is_empty() {
            let held = self
                .world
                .get::<Player>(leader_entity)
                .map_or(0, |p| realm_rules::items::count_items(&p.sheet, &def.key));
            if held < diff.keys {
                return Err(("no_key", String::new(), diff.keys as i32));
            }
        }
        Ok(members.iter().map(|(c, _)| *c).collect())
    }

    /// `ClientMsg::DungeonStart`.
    pub(super) fn dungeon_start(
        &mut self,
        conn: ConnId,
        entity: Entity,
        portal_id: &str,
        difficulty: u8,
    ) {
        let tick = self.tick;
        // In a dungeon: another run from the finished copy.
        if self.instanced {
            return self.dungeon_replay(conn, entity, portal_id, difficulty);
        }
        let Some((portal, def)) = self.gate_of(portal_id) else {
            return self.gate_refuse(conn, "no_portal", "", 0);
        };
        let difficulty = usize::from(difficulty);
        if difficulty >= DIFFICULTIES.len() {
            return self.gate_refuse(conn, "no_portal", "", 0);
        }
        let Some(pos) = self.feet(entity) else { return };
        if !portal.holds(pos) && planar_distance(v3(pos), v3(portal.center)) > portal.radius + 0.5 {
            return self.gate_refuse(conn, "range", "", 0);
        }
        let me = self.world.get::<Player>(entity).map_or(0, |p| p.sheet.id);
        if self.ready_checks.iter().any(|c| c.roster.contains(&me))
            || self.launches.iter().any(|l| l.roster.contains(&me))
        {
            return self.gate_refuse(conn, "ready_pending", "", 0);
        }
        let roster = match self.gate_check(entity, &Gather::Gate(portal), &def, difficulty) {
            Ok(r) => r,
            Err((reason, who, value)) => return self.gate_refuse(conn, reason, &who, value),
        };
        if roster.len() == 1 {
            return self.launch(portal_id, difficulty, me, roster);
        }
        self.next_check += 1;
        let ends = tick + (self.rules().dungeons.group.ready_s * SIM_HZ as f32) as u32;
        let check = Check {
            id: self.next_check,
            portal: portal_id.to_owned(),
            dungeon: def.id.clone(),
            difficulty,
            leader: me,
            roster,
            ready: vec![me],
            ends,
            replay: 0,
        };
        let view = self.ready_view(&check);
        let roster = check.roster.clone();
        self.ready_checks.push(check);
        for ch in roster {
            if let Some((c, _)) = self.player_of(ch) {
                self.send_control(
                    c,
                    &ServerMsg::Dungeon(Box::new(DungeonMsg::Ready(view.clone()))),
                );
            }
        }
    }

    fn cancel_check(&mut self, k: usize, reason: &str, who: &str) {
        let c = self.ready_checks.remove(k);
        for ch in c.roster {
            if let Some((conn, _)) = self.player_of(ch) {
                self.send_control(
                    conn,
                    &ServerMsg::Dungeon(Box::new(DungeonMsg::Cancelled {
                        reason: reason.to_owned(),
                        who: who.to_owned(),
                    })),
                );
            }
        }
    }

    /// `ClientMsg::DungeonReady`.
    pub(super) fn dungeon_ready(&mut self, entity: Entity, id: u32, yes: bool) {
        let Some(me) = self
            .world
            .get::<Player>(entity)
            .map(|p| (p.sheet.id, p.sheet.name.clone()))
        else {
            return;
        };
        let Some(k) = self
            .ready_checks
            .iter()
            .position(|c| c.id == id && c.roster.contains(&me.0))
        else {
            return;
        };
        if !yes {
            return self.cancel_check(k, "declined", &me.1);
        }
        if !self.ready_checks[k].ready.contains(&me.0) {
            self.ready_checks[k].ready.push(me.0);
        }
        let c = &self.ready_checks[k];
        if c.ready.len() == c.roster.len() {
            let c = self.ready_checks.remove(k);
            if c.replay != 0 {
                return self.launch_replay(&c.portal, c.difficulty, c.leader, c.roster, c.replay);
            }
            return self.launch(&c.portal, c.difficulty, c.leader, c.roster);
        }
        let view = self.ready_view(c);
        for ch in c.roster.clone() {
            if let Some((conn, _)) = self.player_of(ch) {
                self.send_control(
                    conn,
                    &ServerMsg::Dungeon(Box::new(DungeonMsg::Ready(view.clone()))),
                );
            }
        }
    }

    /// Ready checks that ran out or whose party changed; launches the
    /// coordinator never answered.
    pub(super) fn tick_checks(&mut self) {
        let tick = self.tick;
        if !tick.is_multiple_of(SIM_HZ) {
            return;
        }
        let mut k = 0;
        while k < self.ready_checks.len() {
            let c = &self.ready_checks[k];
            let leader = self.player_of(c.leader).map(|(_, e)| e);
            let changed = leader.is_none_or(|e| {
                let (_, members) = self.gate_party(e);
                let now: Vec<u64> = members.iter().map(|(c, _)| *c).collect();
                now != c.roster
            });
            if changed {
                self.cancel_check(k, "party_changed", "");
                continue;
            }
            if tick >= c.ends {
                let waiting: Vec<String> = c
                    .roster
                    .iter()
                    .filter(|ch| !c.ready.contains(ch))
                    .filter_map(|ch| {
                        self.player_of(*ch)
                            .and_then(|(_, e)| self.world.get::<Player>(e))
                            .map(|p| p.sheet.name.clone())
                    })
                    .collect();
                self.cancel_check(k, "ready_timeout", &waiting.join(", "));
                continue;
            }
            k += 1;
        }
        let stale: Vec<usize> = self
            .launches
            .iter()
            .enumerate()
            .filter(|(_, l)| tick > l.since + LAUNCH_WAIT_TICKS)
            .map(|(k, _)| k)
            .collect();
        for k in stale.into_iter().rev() {
            let l = self.launches.remove(k);
            if let Some((conn, _)) = self.player_of(l.leader) {
                self.gate_refuse(conn, "map_unavailable", "", 0);
            }
            self.call_off(&l.roster);
        }
        self.sweep_boardings();
    }

    /// Everyone agreed: the rules once more, then a copy is asked for.
    fn launch(&mut self, portal_id: &str, difficulty: usize, leader: u64, roster: Vec<u64>) {
        let rules = self.rules();
        let Some((portal, def)) = self.gate_of(portal_id) else {
            return;
        };
        let Some((leader_conn, leader_entity)) = self.player_of(leader) else {
            return;
        };
        let checked = match self.gate_check(leader_entity, &Gather::Gate(portal), &def, difficulty)
        {
            Ok(r) if r == roster => r,
            Ok(_) => return self.gate_refuse(leader_conn, "party_changed", "", 0),
            Err((reason, who, value)) => return self.gate_refuse(leader_conn, reason, &who, value),
        };
        if self.coord_tx.is_none() || !self.coord_up || !self.open_maps.contains(&def.map) {
            return self.gate_refuse(leader_conn, "map_unavailable", "", 0);
        }
        let day = dungeons::reward_day(super::now_unix());
        let mut members = Vec::new();
        let mut levels = Vec::new();
        for ch in &checked {
            let Some(p) = self
                .player_of(*ch)
                .and_then(|(_, e)| self.world.get::<Player>(e))
            else {
                continue;
            };
            let rights = rules
                .dungeons
                .rights_left(&p.sheet, &def.id, difficulty, day);
            let rewarded = rights != 0;
            let first = rewarded && p.sheet.dungeons.last_rewarded_day != day;
            levels.push(p.sheet.level);
            members.push((*ch, p.sheet.name.clone(), p.sheet.level, rewarded, first));
        }
        let ref_level = rules.dungeons.ref_level(&def, &levels);
        let curses = usize::from(rules.dungeons.difficulties[difficulty].affixes);
        let affixes: Vec<String> = rules
            .dungeons
            .affixes
            .of_week(dungeons::curse_week(super::now_unix()))
            .into_iter()
            .take(curses)
            .collect();
        self.next_check += 1;
        let req = u64::from(self.next_check);
        let keys = rules.dungeons.difficulties[difficulty].keys;
        self.launches.push(Launch {
            req,
            portal: portal_id.to_owned(),
            leader,
            roster: checked,
            keys,
            since: self.tick,
        });
        self.coord_send(MapMsg::OpenCopy {
            req,
            map: def.map.clone(),
            spec: Box::new(RunSpec {
                dungeon: def.id.clone(),
                difficulty: difficulty as u8,
                ref_level,
                roster: members,
                affixes,
            }),
        });
    }

    /// The coordinator found (or did not find) a copy for a launch; a found
    /// copy comes with the whole party's seats held.
    pub(super) fn copy_opened(&mut self, req: u64, copy: u8, reason: &str) {
        let Some(k) = self.launches.iter().position(|l| l.req == req) else {
            return;
        };
        let l = self.launches.remove(k);
        let Some((portal, def)) = self.gate_of(&l.portal) else {
            return self.call_off(&l.roster);
        };
        if copy == 0 {
            if let Some((conn, _)) = self.player_of(l.leader) {
                let reason = if reason.is_empty() {
                    "map_full"
                } else {
                    reason
                };
                self.gate_refuse(conn, reason, "", 0);
            }
            return;
        }
        let spawn = portal.to_spawn.clone();
        self.board(
            copy,
            &def,
            &Gather::Gate(portal),
            spawn,
            l.leader,
            l.roster,
            l.keys,
        );
    }

    /// The party sets off for `copy`, the leader first: nothing is spent
    /// unless everyone can still go and the leader's seat is confirmed.
    #[allow(clippy::too_many_arguments)]
    fn board(
        &mut self,
        copy: u8,
        def: &realm_rules::dungeons::DungeonDef,
        at: &Gather,
        spawn: String,
        leader: u64,
        roster: Vec<u64>,
        keys: u32,
    ) {
        let Some((leader_conn, leader_entity)) = self.player_of(leader) else {
            return self.call_off(&roster);
        };
        // Everyone still able to go, or nobody goes.
        for ch in &roster {
            let Some((_, e)) = self.player_of(*ch) else {
                self.gate_refuse(leader_conn, "party_changed", "", 0);
                return self.call_off(&roster);
            };
            let problem = self.member_problem(e, at, &def.map);
            if !problem.is_empty() {
                let name = self
                    .world
                    .get::<Player>(e)
                    .map(|p| p.sheet.name.clone())
                    .unwrap_or_default();
                self.gate_refuse(leader_conn, problem, &name, 0);
                return self.call_off(&roster);
            }
        }
        let label = self
            .rules()
            .travel
            .maps
            .get(&def.map)
            .map_or_else(|| def.display.clone(), |m| m.display.clone());
        let cost = (keys > 0 && !def.key.is_empty()).then(|| (def.key.clone(), keys));
        self.boardings.push(Boarding {
            leader,
            roster: roster.clone(),
            copy,
            map: def.map.clone(),
            spawn,
            label,
            since: self.tick,
        });
        self.board_member(leader_conn, leader_entity, leader, cost);
        let waiting = self
            .world
            .get::<Player>(leader_entity)
            .is_some_and(|p| p.trip.is_some());
        if !waiting && self.boardings.iter().any(|b| b.leader == leader) {
            // Refused on the spot (the trip's own answer said why).
            self.boardings.retain(|b| b.leader != leader);
            self.gate_refuse(leader_conn, "party_changed", "", 0);
            self.call_off(&roster);
        }
    }

    /// One member's trip into the copy of its boarding party.
    fn board_member(
        &mut self,
        conn: ConnId,
        entity: Entity,
        character: u64,
        cost: Option<(String, u32)>,
    ) {
        let Some(b) = self
            .boardings
            .iter()
            .find(|b| b.roster.contains(&character))
        else {
            return;
        };
        let slot = b.roster.iter().position(|c| *c == character).unwrap_or(0);
        let trip = Trip {
            arrival: Arrival {
                map: b.map.clone(),
                landing: Landing::Ring {
                    spawn: b.spawn.clone(),
                    slot: slot as u8,
                    of: b.roster.len() as u8,
                },
                kind: TripKind::Door,
                copy: b.copy,
            },
            label: b.label.clone(),
            cost,
            combat_lock_ms: 0,
        };
        let map = b.map.clone();
        self.send_control(
            conn,
            &ServerMsg::Dungeon(Box::new(DungeonMsg::Launch { map })),
        );
        self.start_trip(conn, entity, trip, false);
    }

    /// The seats held for a launch that will not go.
    fn call_off(&mut self, roster: &[u64]) {
        self.coord_send(MapMsg::Unreserve {
            characters: roster.to_vec(),
        });
    }

    /// A boarding leader's trip was refused: nobody goes, nothing was paid.
    pub(super) fn boarding_refused(&mut self, leader: u64, reason: &str) {
        let Some(k) = self.boardings.iter().position(|b| b.leader == leader) else {
            return;
        };
        let b = self.boardings.remove(k);
        if let Some((conn, _)) = self.player_of(leader) {
            self.gate_refuse(conn, reason, "", 0);
        }
        self.call_off(&b.roster);
    }

    /// The leader is on its way, its keys paid: the others follow.
    pub(super) fn boarding_followers(&mut self, leader: u64) {
        let Some(k) = self.boardings.iter().position(|b| b.leader == leader) else {
            return;
        };
        let roster = self.boardings[k].roster.clone();
        for ch in roster.iter().filter(|c| **c != leader) {
            if let Some((conn, entity)) = self.player_of(*ch) {
                self.board_member(conn, entity, *ch, None);
            }
        }
        self.boardings.remove(k);
    }

    /// Boardings whose leader never heard back (the coordinator went away).
    fn sweep_boardings(&mut self) {
        let tick = self.tick;
        let stale: Vec<u64> = self
            .boardings
            .iter()
            .filter(|b| tick > b.since + LAUNCH_WAIT_TICKS)
            .map(|b| b.leader)
            .collect();
        for leader in stale {
            self.boarding_refused(leader, "map_unavailable");
        }
    }

    /// The run a party gets: its members' rights, the reference level and
    /// the week's curses for the difficulty.
    fn run_spec(
        &self,
        def: &realm_rules::dungeons::DungeonDef,
        difficulty: usize,
        roster: &[u64],
    ) -> RunSpec {
        let rules = self.rules();
        let day = dungeons::reward_day(super::now_unix());
        let mut members = Vec::new();
        let mut levels = Vec::new();
        for ch in roster {
            let Some(p) = self
                .player_of(*ch)
                .and_then(|(_, e)| self.world.get::<Player>(e))
            else {
                continue;
            };
            let rights = rules
                .dungeons
                .rights_left(&p.sheet, &def.id, difficulty, day);
            let rewarded = rights != 0;
            let first = rewarded && p.sheet.dungeons.last_rewarded_day != day;
            levels.push(p.sheet.level);
            members.push((*ch, p.sheet.name.clone(), p.sheet.level, rewarded, first));
        }
        let curses = usize::from(rules.dungeons.difficulties[difficulty].affixes);
        RunSpec {
            dungeon: def.id.clone(),
            difficulty: difficulty as u8,
            ref_level: rules.dungeons.ref_level(def, &levels),
            roster: members,
            affixes: rules
                .dungeons
                .affixes
                .of_week(dungeons::curse_week(super::now_unix()))
                .into_iter()
                .take(curses)
                .collect(),
        }
    }

    /// `ClientMsg::DungeonStart` in a dungeon: the leader, standing in its
    /// party's finished copy, asks for another run (the result window's
    /// "run it again"); the party gathers in that copy, not at the gate.
    fn dungeon_replay(&mut self, conn: ConnId, entity: Entity, portal_id: &str, difficulty: u8) {
        let tick = self.tick;
        let rules = self.rules();
        let difficulty = usize::from(difficulty);
        let portal = rules
            .travel
            .portals
            .iter()
            .find(|p| p.id == portal_id && p.to_map == self.game.map)
            .cloned();
        let def = rules.dungeons.on_map(&self.game.map).cloned();
        let (Some(portal), Some(def)) = (portal, def) else {
            return self.gate_refuse(conn, "no_portal", "", 0);
        };
        if difficulty >= DIFFICULTIES.len() {
            return self.gate_refuse(conn, "no_portal", "", 0);
        }
        let Some(pos) = self.feet(entity) else { return };
        let copy = self.copy_of(v3(pos));
        let finished = self
            .run_index(copy)
            .and_then(|i| self.runs[i].as_ref())
            .is_some_and(|r| r.complete);
        if !finished {
            return self.gate_refuse(conn, "not_finished", "", 0);
        }
        let me = self.world.get::<Player>(entity).map_or(0, |p| p.sheet.id);
        if self.ready_checks.iter().any(|c| c.roster.contains(&me)) {
            return self.gate_refuse(conn, "ready_pending", "", 0);
        }
        let roster = match self.gate_check(entity, &Gather::Copy(copy), &def, difficulty) {
            Ok(r) => r,
            Err((reason, who, value)) => return self.gate_refuse(conn, reason, &who, value),
        };
        if roster.len() == 1 {
            return self.launch_replay(&portal.id, difficulty, me, roster, copy);
        }
        self.next_check += 1;
        let ends = tick + (rules.dungeons.group.ready_s * SIM_HZ as f32) as u32;
        let check = Check {
            id: self.next_check,
            portal: portal.id.clone(),
            dungeon: def.id.clone(),
            difficulty,
            leader: me,
            roster,
            ready: vec![me],
            ends,
            replay: copy,
        };
        let view = self.ready_view(&check);
        let roster = check.roster.clone();
        self.ready_checks.push(check);
        for ch in roster {
            if let Some((c, _)) = self.player_of(ch) {
                self.send_control(
                    c,
                    &ServerMsg::Dungeon(Box::new(DungeonMsg::Ready(view.clone()))),
                );
            }
        }
    }

    /// Everyone agreed to run again: the rules once more, a fresh copy on
    /// this map, the leader's keys, and the party moves into it.
    fn launch_replay(
        &mut self,
        portal_id: &str,
        difficulty: usize,
        leader: u64,
        roster: Vec<u64>,
        from: u8,
    ) {
        let rules = self.rules();
        let portal = rules
            .travel
            .portals
            .iter()
            .find(|p| p.id == portal_id)
            .cloned();
        let def = rules.dungeons.on_map(&self.game.map).cloned();
        let (Some(portal), Some(def)) = (portal, def) else {
            return;
        };
        let Some((leader_conn, leader_entity)) = self.player_of(leader) else {
            return;
        };
        match self.gate_check(leader_entity, &Gather::Copy(from), &def, difficulty) {
            Ok(r) if r == roster => {}
            Ok(_) => return self.gate_refuse(leader_conn, "party_changed", "", 0),
            Err((reason, who, value)) => {
                return self.gate_refuse(leader_conn, reason, &who, value);
            }
        }
        let keys = rules.dungeons.difficulties[difficulty].keys;
        if keys > 0 && !def.key.is_empty() {
            let held = self
                .world
                .get::<Player>(leader_entity)
                .map_or(0, |p| realm_rules::items::count_items(&p.sheet, &def.key));
            if held < keys {
                return self.gate_refuse(leader_conn, "no_key", "", keys as i32);
            }
        }
        let spec = self.run_spec(&def, difficulty, &roster);
        let copy = self.open_copy_here(&spec);
        if copy == 0 {
            return self.gate_refuse(leader_conn, "map_full", "", 0);
        }
        self.runs_changed();
        println!(
            "[dungeon] copy {from} runs again as copy {copy} for {}",
            roster.len()
        );
        let spawn = portal.to_spawn.clone();
        self.board(copy, &def, &Gather::Copy(from), spawn, leader, roster, keys);
    }

    /// The copy of `map` whose run holds `character` (0: none).
    pub(super) fn run_copy_of(&self, map: &str, character: u64) -> u8 {
        self.dungeon_runs
            .iter()
            .find(|r| r.map == map && r.roster.contains(&character))
            .map_or(0, |r| r.copy)
    }

    /// A ring slot around a spawn point.
    pub(super) fn ring_point(at: Vec3, slot: u8, of: u8) -> Vec3 {
        if of <= 1 {
            return at;
        }
        let a = core::f32::consts::TAU * f32::from(slot) / f32::from(of);
        at + Vec3::new(libm::cosf(a) * RING, 0.0, libm::sinf(a) * RING)
    }
}
