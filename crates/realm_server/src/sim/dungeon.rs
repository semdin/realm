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
use realm_proto::control::{DungeonMsg, GateMember, ReadyView, RunResult, RunView, ServerMsg};
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
}

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

impl Sim {
    // ------------------------------------------------------------ helpers

    fn copy_of(&self, pos: Vec3) -> u8 {
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
        let rules = self.rules();
        let free = self.runs.iter().position(Option::is_none);
        let def = rules
            .dungeons
            .dungeons
            .get(&spec.dungeon)
            .filter(|d| d.map == self.game.map);
        let (Some(i), Some(def)) = (free, def) else {
            self.coord_send(MapMsg::CopyOpened { req, copy: 0 });
            return;
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
        let mut forces_total = 0;
        for step in &def.steps {
            if step.min_difficulty > difficulty {
                continue;
            }
            for e in &step.spawn {
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
        });
        println!(
            "[dungeon] copy {copy} of {} opened: {} at {} for {party} (level {})",
            spec.dungeon, diff.id, spec.ref_level, spec.ref_level
        );
        self.coord_send(MapMsg::CopyOpened { req, copy });
        self.runs_changed();
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
        if let Some(r) = self.runs[i].as_mut()
            && !message.is_empty()
        {
            r.message = message.to_owned();
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
                    let r = self.runs[i].as_mut().expect("live run");
                    r.phase = 2;
                    r.start_tick = tick + GATE_LEAD;
                    self.set_gate(i, "start", true);
                }
                return;
            }
            3 => return,
            _ => {}
        }
        self.credit_forces(i);
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
                if matches!(step.on, Trigger::ClearedAll)
                    && let Some(r) = self.runs[i].as_mut()
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
        self.say(i, &step.message);
        if step.complete {
            self.finish(i, def, false, step.chest.as_ref().map(|c| c.1));
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
        for e in entries {
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
                let exp = self.world.get::<Mob>(entity).map_or(0, |m| m.exp_reward);
                if let Some(mut m) = self.world.get_mut::<Mob>(entity) {
                    // Kills pay the members in the copy, not the hitters.
                    m.exp_reward = 0;
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
                    });
                }
            }
        }
    }

    /// The pack a step's creatures belong to (reused from a closed copy
    /// when one is free).
    fn run_pack(&mut self, i: usize, s: usize, entries: &[SpawnEntry]) -> usize {
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
                arena_radius: template
                    .map(|t| t.arena_radius)
                    .filter(|r| *r > 0.0)
                    .unwrap_or(26.0),
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
        entity
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
    fn member_problem(
        &self,
        member: Entity,
        portal: &realm_rules::travel::Portal,
        dungeon_map: &str,
    ) -> &'static str {
        let tick = self.tick;
        let Some(p) = self.world.get::<Player>(member) else {
            return "not_gathered";
        };
        let center = v3(portal.center);
        let gather = self.rules().dungeons.group.gather_radius;
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
        } else if planar_distance(p.body.pos, center) > gather
            || (p.body.pos.y - center.y).abs() > VERTICAL_GATHER
        {
            "not_gathered"
        } else if self
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
            let status = self.member_problem(*e, &portal, &def.map);
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
        portal: &realm_rules::travel::Portal,
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
            let problem = self.member_problem(*e, portal, &def.map);
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
        let roster = match self.gate_check(entity, &portal, &def, difficulty) {
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
        }
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
        let checked = match self.gate_check(leader_entity, &portal, &def, difficulty) {
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
            }),
        });
    }

    /// The coordinator found (or did not find) a copy for a launch.
    pub(super) fn copy_opened(&mut self, req: u64, copy: u8) {
        let Some(k) = self.launches.iter().position(|l| l.req == req) else {
            return;
        };
        let l = self.launches.remove(k);
        let Some((portal, def)) = self.gate_of(&l.portal) else {
            return;
        };
        let leader = self.player_of(l.leader);
        if copy == 0 {
            if let Some((conn, _)) = leader {
                self.gate_refuse(conn, "map_full", "", 0);
            }
            return;
        }
        // The leader's keys open the gate.
        if l.keys > 0 && !def.key.is_empty() {
            let tick = self.tick;
            let paid = leader.is_some_and(|(_, e)| {
                self.world.get_mut::<Player>(e).is_some_and(|mut p| {
                    let ok = realm_rules::items::take_items(&mut p.sheet, &def.key, l.keys).is_ok();
                    if ok {
                        p.sheet.revision += 1;
                        p.dirty_since.get_or_insert(tick);
                    }
                    ok
                })
            });
            if !paid {
                if let Some((conn, _)) = leader {
                    self.gate_refuse(conn, "no_key", "", l.keys as i32);
                }
                return;
            }
            if let Some((conn, _)) = leader {
                self.send_sheet(conn);
            }
        }
        let label = self
            .rules()
            .travel
            .maps
            .get(&def.map)
            .map_or_else(|| def.display.clone(), |m| m.display.clone());
        let n = l.roster.len() as u8;
        for (slot, ch) in l.roster.iter().enumerate() {
            let Some((conn, entity)) = self.player_of(*ch) else {
                continue;
            };
            self.send_control(
                conn,
                &ServerMsg::Dungeon(Box::new(DungeonMsg::Launch {
                    map: def.map.clone(),
                })),
            );
            let trip = Trip {
                arrival: Arrival {
                    map: def.map.clone(),
                    landing: Landing::Ring {
                        spawn: portal.to_spawn.clone(),
                        slot: slot as u8,
                        of: n,
                    },
                    kind: TripKind::Door,
                    copy,
                },
                label: label.clone(),
                cost: None,
                combat_lock_ms: 0,
            };
            self.start_trip(conn, entity, trip, false);
        }
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
