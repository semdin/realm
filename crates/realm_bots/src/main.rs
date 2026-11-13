//! realm_bots --server 127.0.0.1:7777 --keys keys --count 500 --seconds 120 [--ramp 50]
//!            [--skill shockwave=3]
//!
//! Headless players for load tests. Each bot mints a ticket with the dev key,
//! joins over QUIC exactly like the game client, sends inputs at 30 Hz and
//! decodes every snapshot against its acknowledged baseline. It runs toward
//! the nearest living creature it can see and attacks it; with nothing in
//! sight it wanders. Each bot spends its free skill point on `--skill`
//! (name=spell index, default Shockwave, a throw) and opens every twelfth
//! attack with it, so crowd control runs under load too. Every 5 seconds it prints what the bots received. Exits
//! with an error unless every bot joined and every snapshot decoded.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use quinn::crypto::rustls::QuicClientConfig;
use quinn::{ClientConfig, Endpoint};
use realm_proto::ticket::Ticket;
use realm_proto::{
    EntitySet, Hello, InputBatch, InputFrame, JoinReply, PROTOCOL_VERSION, SigningKey,
};
use realm_sim::Vec3;
use realm_sim::input::MoveInput;
use rustls::pki_types::CertificateDer;

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Default)]
struct Totals {
    connected: AtomicU64,
    refused: AtomicU64,
    failed: AtomicU64,
    bytes: AtomicU64,
    snapshots: AtomicU64,
    decode_errors: AtomicU64,
    attacks: AtomicU64,
    deaths: AtomicU64,
}

struct Options {
    server: SocketAddr,
    keys: PathBuf,
    count: u32,
    seconds: u64,
    ramp: u32,
    /// The skill each bot learns, and its spell index.
    skill: (String, u8),
}

fn options() -> AnyResult<Options> {
    let mut o = Options {
        server: "127.0.0.1:7777".parse()?,
        keys: PathBuf::from("keys"),
        count: 10,
        seconds: 60,
        ramp: 50,
        skill: ("shockwave".to_owned(), 3),
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let value = it.next().ok_or_else(|| format!("{arg} needs a value"))?;
        match arg.as_str() {
            "--server" => o.server = value.parse()?,
            "--keys" => o.keys = PathBuf::from(value),
            "--count" => o.count = value.parse()?,
            "--seconds" => o.seconds = value.parse()?,
            "--ramp" => o.ramp = value.parse()?,
            "--skill" => {
                let (name, index) = value.split_once('=').ok_or("--skill takes name=index")?;
                o.skill = (name.to_owned(), index.parse()?);
            }
            other => return Err(format!("unknown option {other}").into()),
        }
    }
    Ok(o)
}

fn main() -> AnyResult<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| "crypto provider already installed")?;
    let o = options()?;
    let secret: [u8; 32] = std::fs::read(o.keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = Arc::new(SigningKey::from_bytes(&secret));
    let mut roots = rustls::RootCertStore::empty();
    roots.add(CertificateDer::from(std::fs::read(
        o.keys.join("tls.crt.der"),
    )?))?;
    let mut tls = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    tls.alpn_protocols = vec![realm_proto::ALPN.to_vec()];
    let mut config = ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls)?));
    let mut transport = quinn::TransportConfig::default();
    transport.keep_alive_interval(Some(Duration::from_secs(2)));
    config.transport_config(Arc::new(transport));

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async move {
        let totals = Arc::new(Totals::default());
        // One UDP socket per 50 bots.
        let mut endpoints = Vec::new();
        for _ in 0..o.count.div_ceil(50) {
            let mut endpoint = Endpoint::client("0.0.0.0:0".parse()?)?;
            endpoint.set_default_client_config(config.clone());
            endpoints.push(endpoint);
        }
        let deadline = Instant::now() + Duration::from_secs(o.seconds);
        let skill = Arc::new(o.skill.clone());
        let spawner = {
            let totals = totals.clone();
            let endpoints = endpoints.clone();
            tokio::spawn(async move {
                let gap = Duration::from_secs_f64(1.0 / f64::from(o.ramp.max(1)));
                for id in 0..o.count {
                    let endpoint = endpoints[(id / 50) as usize].clone();
                    let (totals, key, skill) = (totals.clone(), key.clone(), skill.clone());
                    tokio::spawn(async move {
                        if let Err(error) = bot(id, endpoint, o.server, &key, &totals, deadline, &skill).await {
                            totals.failed.fetch_add(1, Ordering::Relaxed);
                            if id < 3 {
                                eprintln!("[bot {id}] {error}");
                            }
                        }
                    });
                    tokio::time::sleep(gap).await;
                }
            })
        };
        let started = Instant::now();
        let mut last = (0_u64, 0_u64, Instant::now());
        while Instant::now() < deadline {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let now = Instant::now();
            let bytes = totals.bytes.load(Ordering::Relaxed);
            let snaps = totals.snapshots.load(Ordering::Relaxed);
            let connected = totals.connected.load(Ordering::Relaxed);
            let window = (now - last.2).as_secs_f64();
            let per_bot = |v: u64| if connected > 0 { v as f64 / window / connected as f64 } else { 0.0 };
            println!(
                "[bots {:>4.0}s] connected={} refused={} failed={} | in {:.2} KB/s per bot, {:.1} snapshots/s per bot | decode errors={} attacks={} deaths={}",
                (now - started).as_secs_f64(),
                connected,
                totals.refused.load(Ordering::Relaxed),
                totals.failed.load(Ordering::Relaxed),
                per_bot(bytes - last.0) / 1024.0,
                per_bot(snaps - last.1),
                totals.decode_errors.load(Ordering::Relaxed),
                totals.attacks.load(Ordering::Relaxed),
                totals.deaths.load(Ordering::Relaxed),
            );
            last = (bytes, snaps, now);
        }
        spawner.abort();
        // A load run only counts when every bot got in and every snapshot
        // decoded; anything else is a failure the caller (CI) must see.
        let connected = totals.connected.load(Ordering::Relaxed);
        let errors = totals.decode_errors.load(Ordering::Relaxed);
        if connected < u64::from(o.count) || errors > 0 {
            return Err(format!("{connected} of {} bots connected, {errors} decode errors", o.count).into());
        }
        AnyResult::Ok(())
    })
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn yaw_toward(from: Vec3, to: Vec3) -> u16 {
    let (dx, dz) = (to.x - from.x, to.z - from.z);
    let angle = (-dx).atan2(-dz);
    let turn = if angle < 0.0 {
        angle + std::f32::consts::TAU
    } else {
        angle
    };
    ((turn * (65_536.0 / std::f32::consts::TAU)).round() as u32 & 0xFFFF) as u16
}

async fn bot(
    id: u32,
    endpoint: Endpoint,
    server: SocketAddr,
    key: &SigningKey,
    totals: &Totals,
    deadline: Instant,
    skill: &(String, u8),
) -> AnyResult<()> {
    let connection = endpoint.connect(server, "localhost")?.await?;
    let (mut send, mut recv) = connection.open_bi().await?;
    let ticket = Ticket::new(u64::from(id) + 1, u64::from(id) + 1, unix_now() + 60)?.sign(key);
    send.write_all(&realm_proto::control::frame(&realm_proto::encode_hello(
        &Hello {
            protocol: PROTOCOL_VERSION,
            ticket,
        },
    )))
    .await?;
    // The join stream stays open as the control channel: the first frame is
    // the join reply, later ones (the character sheet) are counted and
    // dropped, and must keep being read or the server's writes stall.
    let mut reader = realm_proto::control::FrameReader::default();
    let mut chunk = [0_u8; 4096];
    let reply_bytes = loop {
        if let Some(frame) = reader.next_frame()? {
            break frame;
        }
        let n = recv.read(&mut chunk).await?.ok_or("join stream closed")?;
        reader.push(&chunk[..n]);
    };
    let reply = realm_proto::decode_join_reply(&reply_bytes)?;
    let me = match reply {
        JoinReply::Accepted { entity, .. } => entity,
        JoinReply::Refused(reason) => {
            totals.refused.fetch_add(1, Ordering::Relaxed);
            return Err(format!("refused: {reason}").into());
        }
    };
    totals.connected.fetch_add(1, Ordering::Relaxed);
    // encode_client frames the message itself.
    send.write_all(&realm_proto::control::encode_client(
        &realm_proto::control::ClientMsg::LearnSkill(skill.0.clone()),
    ))
    .await?;
    let skill_action = skill.1 + 1;
    let mut attacks = 0_u32;
    let _drain = tokio::spawn(async move {
        let _keep_open = send;
        let mut chunk = [0_u8; 4096];
        while let Ok(Some(_)) = recv.read(&mut chunk).await {}
    });

    let mut history: VecDeque<(u32, EntitySet)> = VecDeque::new();
    let mut acked = 0_u32;
    let mut own = Vec3::ZERO;
    let mut own_hp = 255_u8;
    let mut seq = 0_u32;
    // Like a real client, a bot casts only when its basic attack is ready
    // again (0.55 s cooldown, 17 ticks): a request every tick would only be
    // refused.
    let mut ready_at = 0_u32;
    let mut sent: VecDeque<InputFrame> = VecDeque::new();
    let mut rng = getrandom::u32()? | 1;
    let mut wander_yaw = (rng & 0xFFFF) as u16;
    let mut ticker =
        tokio::time::interval(Duration::from_secs_f64(1.0 / f64::from(realm_sim::SIM_HZ)));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    while Instant::now() < deadline {
        tokio::select! {
            _ = ticker.tick() => {
                seq += 1;
                let entities = history.back().map(|(_, e)| e);
                let target = entities.and_then(|set| {
                    set.iter()
                        .filter(|(eid, e)| *eid != me && e.kind > 0 && e.hp > 0 && e.state != 3)
                        .map(|(eid, e)| (*eid, e.pos, (e.pos - own).length()))
                        .filter(|t| t.2 < 28.0)
                        .min_by(|a, b| a.2.total_cmp(&b.2))
                });
                let frame = if own_hp == 0 {
                    InputFrame { tick: acked + 3, ..InputFrame::default() }
                } else if let Some((target_id, pos, dist)) = target {
                    let yaw = yaw_toward(own, pos);
                    let circle = if (seq / 90).is_multiple_of(2) { 90 } else { -90 };
                    let (strafe, forward) = if dist > 14.0 { (0, 127) } else { (circle, 0) };
                    let fire = seq >= ready_at;
                    let mut action = 0;
                    if fire {
                        // Shockwave's 6.5 s cooldown is shorter than twelve
                        // basic casts (12 x 17 ticks).
                        let opener = attacks.is_multiple_of(12);
                        action = if opener { skill_action } else { 1 };
                        ready_at = seq + 17;
                        attacks += 1;
                        totals.attacks.fetch_add(1, Ordering::Relaxed);
                    }
                    InputFrame {
                        tick: acked + 3,
                        movement: MoveInput { strafe, forward, yaw, buttons: 0 }, action, target: target_id, aim: [0; 3] }
                        .aimed_at(pos + Vec3::new(0.0, 1.15, 0.0))
                } else {
                    if seq.is_multiple_of(60) {
                        rng ^= rng << 13;
                        rng ^= rng >> 17;
                        rng ^= rng << 5;
                        wander_yaw = (rng & 0xFFFF) as u16;
                    }
                    InputFrame {
                        tick: acked + 3,
                        movement: MoveInput { strafe: 0, forward: 127, yaw: wander_yaw, buttons: 0 }, action: 0, target: 0, aim: [0; 3] }
                };
                sent.push_back(frame);
                while sent.len() > 4 {
                    sent.pop_front();
                }
                let batch = InputBatch { newest_seq: seq, ack_snapshot: acked, inputs: sent.iter().copied().collect() };
                let _ = connection.send_datagram(realm_proto::encode_inputs(&batch).into());
            }
            datagram = connection.read_datagram() => {
                let bytes = datagram?;
                totals.bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
                let decoded = realm_proto::decode_snapshot(&bytes, |tick| {
                    history.iter().find(|(t, _)| *t == tick).map(|(_, e)| e.as_slice())
                });
                match decoded {
                    Ok(snapshot) => {
                        totals.snapshots.fetch_add(1, Ordering::Relaxed);
                        if snapshot.own_hp == 0 && own_hp != 0 {
                            totals.deaths.fetch_add(1, Ordering::Relaxed);
                        }
                        own = snapshot.own.pos;
                        own_hp = snapshot.own_hp;
                        if snapshot.tick > acked {
                            acked = snapshot.tick;
                            history.push_back((snapshot.tick, snapshot.entities));
                            while history.len() > 40 {
                                history.pop_front();
                            }
                        }
                    }
                    Err(_) => {
                        totals.decode_errors.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
        }
    }
    connection.close(0u32.into(), b"done");
    Ok(())
}
