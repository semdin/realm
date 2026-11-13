//! realm_simcheck [--trace <scenario>]
//!
//! Plays scripted inputs through `realm_sim::movement` on a fixed test world
//! (flat ground, stairs, a walkable ramp, a too-steep bank, a wall, a pool,
//! rolling hills, open sky for the broom) and prints, per scenario, where the
//! body ended up and a fingerprint of every state bit along the way. The rules
//! are deterministic, so every platform must print the same text; CI runs it
//! on Windows, Linux and macOS (ARM) and fails when any line differs.
//! `--trace` prints the body every 10 ticks for one scenario.
//!
//! Every tick the body also goes through the wire format and must come back
//! identical (the client rewinds to exactly what the server sent), and a
//! synthetic crowd measures what delta snapshots cost.

use std::collections::BTreeMap;

use realm_proto::EntitySet;

use realm_proto::{EntityState, InputBatch, InputFrame, Snapshot};
use realm_sim::input::MoveInput;
use realm_sim::movement::{self, Body, MoveParams};
use realm_sim::world::{WaterArea, World};
use realm_sim::{SIM_HZ, Vec3};

/// One stretch of constant input.
struct Segment {
    seconds: f32,
    input: MoveInput,
    /// Knock-back applied at the start of the stretch.
    shove: Option<Vec3>,
}

struct Scenario {
    name: &'static str,
    start: Vec3,
    mounted: bool,
    segments: Vec<Segment>,
}

const QUARTER: u16 = 16_384;

fn hold(seconds: f32, strafe: i8, forward: i8, yaw: u16, buttons: u8) -> Segment {
    Segment {
        seconds,
        input: MoveInput {
            strafe,
            forward,
            yaw,
            buttons,
        },
        shove: None,
    }
}

fn idle(seconds: f32) -> Segment {
    hold(seconds, 0, 0, 0, 0)
}

fn scenarios() -> Vec<Scenario> {
    let jump = MoveInput::JUMP;
    let down = MoveInput::DESCEND;
    vec![
        Scenario {
            name: "walk_flat",
            start: Vec3::new(0.0, 0.0, 0.0),
            mounted: false,
            segments: vec![
                idle(0.5),
                hold(3.0, 0, 127, 0, 0),
                hold(2.0, 90, 90, 9_000, 0),
                idle(1.0),
            ],
        },
        Scenario {
            name: "jumps",
            start: Vec3::new(5.0, 0.0, 0.0),
            mounted: false,
            segments: vec![
                idle(0.5),
                hold(0.1, 0, 127, QUARTER, jump),
                hold(0.6, 0, 127, QUARTER, 0),
                // pressed a moment before landing: the buffer still jumps
                hold(0.1, 0, 127, QUARTER, jump),
                hold(1.2, 0, 127, QUARTER, 0),
                idle(1.0),
            ],
        },
        Scenario {
            name: "stairs",
            start: Vec3::new(21.0, 0.0, 6.0),
            mounted: false,
            // yaw half a turn: forward is +Z, up the flight
            segments: vec![idle(0.5), hold(3.0, 0, 127, 2 * QUARTER, 0), idle(0.5)],
        },
        Scenario {
            name: "ramp_up_down",
            start: Vec3::new(-20.0, 0.0, 6.0),
            mounted: false,
            segments: vec![
                idle(0.5),
                hold(2.5, 0, 127, 2 * QUARTER, 0),
                hold(2.5, 0, 127, 0, 0),
                idle(0.5),
            ],
        },
        Scenario {
            name: "steep_slide",
            start: Vec3::new(-40.0, 6.0, 13.0),
            mounted: false,
            // tries to walk up the bank, slides back down instead
            segments: vec![hold(3.0, 0, 127, 2 * QUARTER, 0), idle(1.0)],
        },
        Scenario {
            name: "wall_slide",
            start: Vec3::new(35.0, 0.0, -3.0),
            mounted: false,
            // runs diagonally into the wall at x = 40 and slides along it
            segments: vec![idle(0.5), hold(2.5, -127, 127, 2 * QUARTER, 0), idle(0.5)],
        },
        Scenario {
            name: "swim",
            start: Vec3::new(52.0, 0.0, 0.0),
            mounted: false,
            segments: vec![
                idle(0.5),
                hold(2.0, 127, 0, 0, 0),
                hold(1.5, 127, 0, 0, jump),
                hold(2.0, 0, 127, 0, 0),
                idle(1.0),
            ],
        },
        Scenario {
            name: "hills",
            start: Vec3::new(0.0, 6.0, -150.0),
            mounted: false,
            segments: (0..12)
                .map(|i| {
                    hold(
                        0.75,
                        0,
                        127,
                        (i * 5_461) as u16,
                        if i == 6 { jump } else { 0 },
                    )
                })
                .chain([idle(1.0)])
                .collect(),
        },
        Scenario {
            name: "broom",
            start: Vec3::new(0.0, 0.0, 50.0),
            mounted: true,
            segments: vec![
                idle(1.0),
                hold(5.0, 0, 127, 0, jump),
                hold(3.0, 60, 127, 3_000, 0),
                hold(2.0, 0, 0, 3_000, down),
                idle(1.0),
            ],
        },
        Scenario {
            name: "shove",
            start: Vec3::new(-5.0, 0.0, -20.0),
            mounted: false,
            segments: vec![
                idle(0.5),
                Segment {
                    seconds: 1.0,
                    input: MoveInput::default(),
                    shove: Some(Vec3::new(9.0, 0.0, -4.0)),
                },
                hold(1.0, 0, 127, 0, 0),
                idle(0.5),
            ],
        },
    ]
}

/// The fixed test world. Every number here is part of the fingerprint.
fn test_world() -> World {
    let mut world = World::new(40.0, 20.0);
    // Ground, with a 2 m deep pool cut out between x = 55 and x = 85.
    world.add_box(Vec3::new(-22.5, -0.5, 0.0), Vec3::new(77.5, 0.5, 100.0));
    world.add_box(Vec3::new(102.5, -0.5, 0.0), Vec3::new(17.5, 0.5, 100.0));
    world.add_box(Vec3::new(70.0, -2.5, 0.0), Vec3::new(15.0, 0.5, 100.0));
    world.add_water(WaterArea {
        min_x: 55.0,
        max_x: 85.0,
        min_z: -100.0,
        max_z: 100.0,
        surface_y: 0.0,
        min_depth: None,
    });
    // Stairs: ten 0.2 m treads, 0.35 m deep, up +Z from z = 10, then a landing.
    for k in 1..=10 {
        let top = 0.2 * k as f32;
        let z0 = 10.0 + 0.35 * (k - 1) as f32;
        world.add_box(
            Vec3::new(21.0, top * 0.5, z0 + 0.175),
            Vec3::new(3.0, top * 0.5, 0.175),
        );
    }
    world.add_box(Vec3::new(21.0, 1.0, 16.75), Vec3::new(3.0, 1.0, 3.25));
    // A 30 degree ramp (walkable) and a 60 degree bank (too steep), rising +Z.
    for (x, degrees) in [(-20.0_f32, 30.0_f32), (-40.0, 60.0)] {
        let angle = degrees.to_radians();
        let (s, c) = (libm::sinf(angle), libm::cosf(angle));
        let (half_len, half_thick) = (6.0, 0.5);
        let center = Vec3::new(
            x,
            half_len * s - half_thick * c,
            10.0 + half_len * c + half_thick * s,
        );
        world.add_tilted_box(center, Vec3::new(3.0, half_thick, half_len), -angle);
    }
    // A wall 3 m high across x = 40.
    world.add_box(Vec3::new(40.5, 1.5, 0.0), Vec3::new(0.5, 1.5, 8.0));
    // Rolling hills south of the flat ground.
    let (rows, cols) = (33_usize, 33_usize);
    let mut heights = Vec::with_capacity(rows * cols);
    for row in 0..rows {
        for col in 0..cols {
            let x = col as f32 * 100.0 / 32.0;
            let z = row as f32 * 100.0 / 32.0;
            heights.push(3.0 * libm::sinf(x / 7.0) * libm::cosf(z / 9.0));
        }
    }
    world.add_heightfield(
        Vec3::new(0.0, 0.0, -150.0),
        rows,
        cols,
        &heights,
        100.0,
        100.0,
    );
    world
}

/// FNV-1a over the exact bits of the state.
struct Fingerprint(u64);

impl Fingerprint {
    fn new() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }

    fn bytes(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.0 ^= u64::from(*b);
            self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
        }
    }

    fn vec(&mut self, v: Vec3) {
        for c in [v.x, v.y, v.z] {
            self.bytes(&c.to_bits().to_le_bytes());
        }
    }

    fn body(&mut self, b: &Body) {
        self.vec(b.pos);
        self.vec(b.vel);
        self.vec(b.shove);
        self.vec(b.steep_normal);
        self.bytes(&b.slide_speed.to_bits().to_le_bytes());
        self.bytes(&[
            u8::from(b.on_floor),
            u8::from(b.mounted),
            u8::from(b.swimming),
            u8::from(b.prev_jump),
        ]);
        self.bytes(&b.air_ticks.to_le_bytes());
        self.bytes(&[b.jump_buffer, b.steep_ticks]);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let trace = args
        .iter()
        .position(|a| a == "--trace")
        .and_then(|i| args.get(i + 1))
        .cloned();
    let world = test_world();
    if args.iter().any(|a| a == "--bench") {
        bench(&world);
        return;
    }
    let params = MoveParams::default();
    let mut all = Fingerprint::new();
    println!("realm_simcheck: sim {SIM_HZ} Hz");
    for scenario in scenarios() {
        let mut body = Body::at(scenario.start);
        body.mounted = scenario.mounted;
        let mut print = Fingerprint::new();
        let mut tick = 0_u32;
        let tracing = trace.as_deref() == Some(scenario.name);
        for segment in &scenario.segments {
            if let Some(shove) = segment.shove {
                body.shove = shove;
            }
            let steps = libm::roundf(segment.seconds * SIM_HZ as f32) as u32;
            for _ in 0..steps {
                movement::step(&mut body, segment.input, &params, &world);
                wire_round_trip(&body, segment.input, tick);
                print.body(&body);
                tick += 1;
                if tracing && tick.is_multiple_of(10) {
                    println!(
                        "  t={tick:4} pos=({:8.3},{:7.3},{:8.3}) vel=({:6.2},{:6.2},{:6.2}) floor={} swim={} steep={}",
                        body.pos.x,
                        body.pos.y,
                        body.pos.z,
                        body.vel.x,
                        body.vel.y,
                        body.vel.z,
                        u8::from(body.on_floor),
                        u8::from(body.swimming),
                        body.steep_ticks
                    );
                }
            }
        }
        assert!(
            body.pos.is_finite() && body.vel.is_finite(),
            "{}: state is not finite: {body:?}",
            scenario.name
        );
        all.bytes(&print.0.to_le_bytes());
        println!(
            "{:<13} ticks={tick:4} end=({:9.4},{:8.4},{:9.4}) floor={} swim={} hash={:016x}",
            scenario.name,
            body.pos.x,
            body.pos.y,
            body.pos.z,
            u8::from(body.on_floor),
            u8::from(body.swimming),
            print.0
        );
    }
    let crowd = crowd_bandwidth();
    all.bytes(crowd.as_bytes());
    println!("{crowd}");
    println!("all={:016x}", all.0);
}

/// `--bench`: cost of one movement step per scenario (not part of the
/// fingerprint; timings differ between machines).
fn bench(world: &World) {
    let params = MoveParams::default();
    for scenario in scenarios() {
        let mut steps = 0_u64;
        let started = std::time::Instant::now();
        for _ in 0..50 {
            let mut body = Body::at(scenario.start);
            body.mounted = scenario.mounted;
            for segment in &scenario.segments {
                let n = libm::roundf(segment.seconds * SIM_HZ as f32) as u32;
                for _ in 0..n {
                    movement::step(&mut body, segment.input, &params, world);
                    steps += 1;
                }
            }
        }
        let us = started.elapsed().as_secs_f64() * 1e6 / steps as f64;
        println!("{:<13} {us:6.2} us/step", scenario.name);
    }
}

/// The owner's body and its input must survive the wire bit for bit.
fn wire_round_trip(body: &Body, input: MoveInput, tick: u32) {
    let snapshot = Snapshot {
        tick: tick + 1,
        baseline_tick: 0,
        last_input_seq: tick,
        own: *body,
        own_hp: 200,
        entities: Vec::new(),
    };
    let decoded =
        realm_proto::decode_snapshot(&realm_proto::encode_snapshot(&snapshot, None), |_| None)
            .expect("own snapshot decodes");
    assert_eq!(decoded, snapshot, "body changed on the wire at tick {tick}");
    let frame = InputFrame {
        movement: input,
        action: (tick % 3) as u8,
        target: tick * 7,
    };
    let batch = InputBatch {
        newest_seq: tick,
        ack_snapshot: tick,
        inputs: vec![frame; 3],
    };
    let back =
        realm_proto::decode_inputs(&realm_proto::encode_inputs(&batch)).expect("inputs decode");
    let expected = InputBatch {
        inputs: batch
            .inputs
            .iter()
            .map(|f| InputFrame {
                target: if f.action == 0 { 0 } else { f.target },
                ..*f
            })
            .collect(),
        ..batch
    };
    assert_eq!(back, expected, "input changed on the wire at tick {tick}");
}

/// 100 entities walking circles at 6.5 m/s, a third of them idle at any time;
/// one snapshot per tick, delta-coded against the snapshot three ticks back
/// (the client's acknowledgement lags a round trip). Prints the average size.
fn crowd_bandwidth() -> String {
    const ENTITIES: u32 = 100;
    const TICKS: u32 = 300;
    const ACK_LAG: u32 = 3;
    let mut history: BTreeMap<u32, EntitySet> = BTreeMap::new();
    let mut total_bytes = 0_usize;
    for tick in 1..=TICKS {
        let mut entities: EntitySet = Vec::new();
        for id in 0..ENTITIES {
            // Every entity leaves the set for a while now and then, so
            // removals and re-entries are on the wire too.
            if (tick / 50 + id).is_multiple_of(7) {
                continue;
            }
            let walking = (tick / 40 + id) % 3 != 0;
            let t = if walking {
                tick as f32
            } else {
                (tick - tick % 40) as f32
            };
            let angle = t * realm_sim::SIM_DT * 6.5 / 8.0 + id as f32;
            let center = Vec3::new((id % 10) as f32 * 20.0, 0.0, (id / 10) as f32 * 20.0);
            let raw = center + Vec3::new(8.0 * libm::cosf(angle), 0.0, 8.0 * libm::sinf(angle));
            let pos = Vec3::new(snap(raw.x), snap(raw.y), snap(raw.z));
            let yaw = (libm::roundf(angle * 10_430.378) as i32 & 0xFFFF) as u16;
            entities.push((
                id * 7 + 3,
                EntityState {
                    pos,
                    yaw,
                    state: u8::from(walking),
                    kind: (id % 5) as u16,
                    hp: 255 - (tick / 30) as u8,
                },
            ));
        }
        let baseline_tick = tick.saturating_sub(ACK_LAG);
        let baseline = history.get(&baseline_tick);
        let snapshot = Snapshot {
            tick,
            baseline_tick: if baseline.is_some() { baseline_tick } else { 0 },
            last_input_seq: tick,
            own: Body::default(),
            own_hp: 255,
            entities: entities.clone(),
        };
        let bytes = realm_proto::encode_snapshot(&snapshot, baseline.map(Vec::as_slice));
        let decoded = realm_proto::decode_snapshot(&bytes, |t| history.get(&t).map(Vec::as_slice))
            .expect("crowd snapshot decodes");
        assert_eq!(
            decoded.entities, entities,
            "crowd changed on the wire at tick {tick}"
        );
        total_bytes += bytes.len();
        history.insert(tick, entities);
        history.retain(|t, _| *t + 8 > tick);
    }
    let average = total_bytes as f32 / TICKS as f32;
    format!(
        "crowd         {ENTITIES} entities, delta vs {ACK_LAG} ticks back: {average:.1} bytes/snapshot = {:.2} KB/s at 20 Hz",
        average * 20.0 / 1024.0
    )
}

fn snap(v: f32) -> f32 {
    libm::roundf(v * realm_sim::WIRE_GRID) / realm_sim::WIRE_GRID
}
