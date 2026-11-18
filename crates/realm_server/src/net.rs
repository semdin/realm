//! QUIC side of the map server. Each connection: a join stream (a Hello frame
//! with a signed ticket -> a JoinReply frame) that then stays open as the
//! control channel (framed messages both ways), inputs in and snapshots out as
//! datagrams. Nothing here touches game state; it forwards to the simulation
//! thread and writes what it gets back.
//!
//! What one peer can cost the others is bounded here. Before it has shown a
//! ticket: handshakes per address and in all, a QUIC Retry when many are under
//! way, and a deadline for the whole join. After: a budget of inputs and of
//! control messages per second and a bounded queue to the simulation. A peer
//! over budget loses those messages; one that keeps at it is closed.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use crossbeam_channel::Sender;
use quinn::crypto::rustls::QuicServerConfig;
use quinn::{Endpoint, ServerConfig, TransportConfig, VarInt};
use realm_proto::control::{self, ClientMsg, FrameReader};
use realm_proto::ticket::Ticket;
use realm_proto::{JoinReply, PROTOCOL_VERSION, VerifyingKey};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

use crate::selfcheck::AnyResult;
use crate::sim::{CONTROL_QUEUE, ConnId, Held, NetEvent};

/// Malformed datagrams a connection may send before it is closed.
const MALFORMED_LIMIT: u32 = 50;
/// Snapshots waiting for a slow connection; older ones are dropped (the next
/// snapshot supersedes them anyway).
const OUTBOX: usize = 4;

/// From the first packet to a joined player, at most this long.
const JOIN_DEADLINE: Duration = Duration::from_secs(10);
/// Connections still without a valid ticket, in all and from one address.
const UNPROVEN_MAX: u32 = 256;
const UNPROVEN_PER_IP: u32 = 8;
/// New connections from one address in one window. Both per-address limits can
/// be raised for load tests from one machine: REALM_UNPROVEN_PER_IP and
/// REALM_NEW_PER_IP.
const NEW_PER_IP: u32 = 60;
const NEW_WINDOW: Duration = Duration::from_secs(10);
/// With this many unproven connections, a peer proves its address first.
const RETRY_ABOVE: u32 = 32;

/// Inputs per second a client may send (it sends 30, more catching up).
const INPUT_RATE: f64 = 90.0;
const INPUT_BURST: f64 = 150.0;
/// Control messages per second.
const CONTROL_RATE: f64 = 30.0;
const CONTROL_BURST: f64 = 90.0;
/// Messages of one connection waiting for the simulation.
const QUEUE_MAX: u32 = 256;
/// Dropped in one window before the connection is closed.
const DROPS_INPUT_MAX: u32 = 2000;
const DROPS_CONTROL_MAX: u32 = 300;
const DROP_WINDOW: Duration = Duration::from_secs(10);

/// A rate with a burst.
struct Budget {
    tokens: f64,
    rate: f64,
    burst: f64,
    at: Instant,
}

impl Budget {
    fn new(rate: f64, burst: f64) -> Self {
        Self {
            tokens: burst,
            rate,
            burst,
            at: Instant::now(),
        }
    }

    fn take(&mut self, cost: f64) -> bool {
        let now = Instant::now();
        self.tokens = (self.tokens + (now - self.at).as_secs_f64() * self.rate).min(self.burst);
        self.at = now;
        if self.tokens < cost {
            return false;
        }
        self.tokens -= cost;
        true
    }
}

/// What a control message costs: asking who is near is cheap, a crowd coming
/// into view asks for every one of them.
fn control_cost(msg: &ClientMsg) -> f64 {
    match msg {
        ClientMsg::Inspect(_) => 0.2,
        _ => 1.0,
    }
}

/// What one connection may still send.
struct Meter {
    inputs: Budget,
    control: Budget,
    queued: Arc<AtomicU32>,
    window: Instant,
    dropped_inputs: u32,
    dropped_control: u32,
    warned: bool,
}

impl Meter {
    fn new() -> Self {
        Self {
            inputs: Budget::new(INPUT_RATE, INPUT_BURST),
            control: Budget::new(CONTROL_RATE, CONTROL_BURST),
            queued: Arc::new(AtomicU32::new(0)),
            window: Instant::now(),
            dropped_inputs: 0,
            dropped_control: 0,
            warned: false,
        }
    }

    /// A place in the queue to the simulation.
    fn hold(&self) -> Option<Held> {
        if self.queued.load(Ordering::Relaxed) >= QUEUE_MAX {
            return None;
        }
        self.queued.fetch_add(1, Ordering::Relaxed);
        Some(Held(self.queued.clone()))
    }

    fn tick_window(&mut self) {
        if self.window.elapsed() >= DROP_WINDOW {
            self.window = Instant::now();
            self.dropped_inputs = 0;
            self.dropped_control = 0;
            self.warned = false;
        }
    }

    /// May this input go on? Err: the connection has to go.
    fn input(&mut self) -> Result<Option<Held>, &'static str> {
        self.tick_window();
        let held = if self.inputs.take(1.0) {
            self.hold()
        } else {
            None
        };
        if held.is_none() {
            self.dropped_inputs += 1;
            if self.dropped_inputs > DROPS_INPUT_MAX {
                return Err("too many inputs");
            }
        }
        Ok(held)
    }

    fn control(&mut self, msg: &ClientMsg) -> Result<Option<Held>, &'static str> {
        self.tick_window();
        let held = if self.control.take(control_cost(msg)) {
            self.hold()
        } else {
            None
        };
        if held.is_none() {
            self.dropped_control += 1;
            if self.dropped_control > DROPS_CONTROL_MAX {
                return Err("too many messages");
            }
        }
        Ok(held)
    }

    /// True the first time in a window that something was dropped.
    fn first_drop(&mut self) -> bool {
        if self.dropped_inputs + self.dropped_control > 0 && !self.warned {
            self.warned = true;
            return true;
        }
        false
    }
}

/// Connections that have not shown a valid ticket yet.
fn env_limit(name: &str, default: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

#[derive(Default)]
struct Gatehouse {
    unproven_per_ip: u32,
    new_per_ip: u32,
    unproven: HashMap<IpAddr, u32>,
    total: u32,
    recent: HashMap<IpAddr, (Instant, u32)>,
    refused: u64,
    told: Option<Instant>,
}

enum Verdict {
    Go,
    Retry,
    Refuse,
}

impl Gatehouse {
    fn judge(&mut self, ip: IpAddr, validated: bool, may_retry: bool) -> Verdict {
        let now = Instant::now();
        if self.recent.len() > 20_000 {
            self.recent.retain(|_, (at, _)| now - *at < NEW_WINDOW);
        }
        let (at, count) = self.recent.entry(ip).or_insert((now, 0));
        if now - *at >= NEW_WINDOW {
            (*at, *count) = (now, 0);
        }
        *count += 1;
        let flooding = *count > self.new_per_ip;
        let from_ip = self.unproven.get(&ip).copied().unwrap_or(0);
        if flooding || from_ip >= self.unproven_per_ip || self.total >= UNPROVEN_MAX {
            self.refused += 1;
            if self.told.is_none_or(|t| now - t > Duration::from_secs(30)) {
                self.told = Some(now);
                eprintln!(
                    "[alert] net: refusing connections ({} so far, {} unproven now)",
                    self.refused, self.total
                );
            }
            return Verdict::Refuse;
        }
        if self.total >= RETRY_ABOVE && !validated && may_retry {
            return Verdict::Retry;
        }
        *self.unproven.entry(ip).or_insert(0) += 1;
        self.total += 1;
        Verdict::Go
    }

    fn proven(&mut self, ip: IpAddr) {
        self.total = self.total.saturating_sub(1);
        if let Some(n) = self.unproven.get_mut(&ip) {
            *n -= 1;
            if *n == 0 {
                self.unproven.remove(&ip);
            }
        }
    }
}

/// A connection's place among the unproven, given back when it joins or ends.
struct Unproven {
    gate: Arc<Mutex<Gatehouse>>,
    ip: IpAddr,
}

impl Drop for Unproven {
    fn drop(&mut self) {
        if let Ok(mut g) = self.gate.lock() {
            g.proven(self.ip);
        }
    }
}

pub fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

pub fn transport() -> TransportConfig {
    let mut transport = TransportConfig::default();
    transport.max_idle_timeout(Some(VarInt::from_u32(10_000).into()));
    transport.keep_alive_interval(Some(Duration::from_secs(2)));
    transport.max_concurrent_bidi_streams(VarInt::from_u32(1));
    transport.max_concurrent_uni_streams(VarInt::from_u32(0));
    transport.datagram_receive_buffer_size(Some(64 * 1024));
    // What a client may have in flight towards the server.
    transport.stream_receive_window(VarInt::from_u32(128 * 1024));
    transport.receive_window(VarInt::from_u32(256 * 1024));
    transport
}

pub fn endpoint(bind: &str, cert_der: Vec<u8>, key_der: Vec<u8>) -> AnyResult<Endpoint> {
    let mut tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(cert_der)],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der)),
        )?;
    tls.alpn_protocols = vec![realm_proto::ALPN.to_vec()];
    let mut config = ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    config.transport_config(Arc::new(transport()));
    config.max_incoming(4096);
    config.incoming_buffer_size(16 * 1024);
    config.incoming_buffer_size_total(8 * 1024 * 1024);
    Ok(Endpoint::server(config, bind.parse()?)?)
}

/// A login's claim may take this long past the join deadline (the coordinator
/// moving the character from another map; see travel.rs CLAIM_WAIT_TICKS).
const CLAIM_MARGIN: Duration = Duration::from_secs(25);

/// Seen ticket nonces until their expiry: a ticket joins once.
type Nonces = Arc<Mutex<HashMap<u64, u64>>>;

pub async fn accept_loop(endpoint: Endpoint, sim: Sender<NetEvent>, key: VerifyingKey) {
    let nonces: Nonces = Arc::default();
    let gate = Arc::new(Mutex::new(Gatehouse {
        unproven_per_ip: env_limit("REALM_UNPROVEN_PER_IP", UNPROVEN_PER_IP),
        new_per_ip: env_limit("REALM_NEW_PER_IP", NEW_PER_IP),
        ..Gatehouse::default()
    }));
    let mut next_conn: ConnId = 1;
    while let Some(incoming) = endpoint.accept().await {
        let ip = incoming.remote_address().ip();
        let verdict = gate.lock().map_or(Verdict::Refuse, |mut g| {
            g.judge(
                ip,
                incoming.remote_address_validated(),
                incoming.may_retry(),
            )
        });
        match verdict {
            Verdict::Refuse => {
                incoming.refuse();
                continue;
            }
            Verdict::Retry => {
                let _ = incoming.retry();
                continue;
            }
            Verdict::Go => {}
        }
        let unproven = Unproven {
            gate: gate.clone(),
            ip,
        };
        let conn = next_conn;
        next_conn += 1;
        let (sim, nonces) = (sim.clone(), nonces.clone());
        tokio::spawn(async move {
            if let Err(error) = connection(incoming, conn, sim, key, nonces, unproven).await {
                eprintln!("[net] connection {conn}: {error}");
            }
        });
    }
}

/// Reads from `recv` until `reader` holds a whole frame.
async fn next_frame(
    recv: &mut quinn::RecvStream,
    reader: &mut FrameReader,
) -> AnyResult<Option<Vec<u8>>> {
    let mut chunk = [0_u8; 4096];
    loop {
        if let Some(frame) = reader.next_frame()? {
            return Ok(Some(frame));
        }
        match recv.read(&mut chunk).await? {
            Some(n) => reader.push(&chunk[..n]),
            None => return Ok(None),
        }
    }
}

async fn connection(
    incoming: quinn::Incoming,
    conn: ConnId,
    sim: Sender<NetEvent>,
    key: VerifyingKey,
    nonces: Nonces,
    unproven: Unproven,
) -> AnyResult<()> {
    let began = Instant::now();
    let connection = tokio::time::timeout(JOIN_DEADLINE, incoming).await??;
    let (mut send, mut recv) =
        tokio::time::timeout(Duration::from_secs(5), connection.accept_bi()).await??;
    let mut reader = FrameReader::with_limit(control::MAX_CLIENT_FRAME);
    let hello_bytes =
        tokio::time::timeout(Duration::from_secs(5), next_frame(&mut recv, &mut reader))
            .await??
            .ok_or("join stream closed before the hello")?;

    let refuse = |reason: &str| JoinReply::Refused(reason.to_owned());
    let verdict = match realm_proto::decode_hello(&hello_bytes) {
        Err(_) => Err(refuse("malformed hello")),
        Ok(hello) if hello.protocol != PROTOCOL_VERSION => {
            Err(refuse("client version does not match the server"))
        }
        Ok(hello) => match Ticket::verify(&hello.ticket, &key, now_unix()) {
            Err(error) => Err(refuse(&error.to_string())),
            Ok(ticket) => {
                let mut seen = nonces.lock().map_err(|_| "nonce table poisoned")?;
                let now = now_unix();
                seen.retain(|_, expires| *expires >= now);
                if seen.insert(ticket.nonce, ticket.expires_unix).is_some() {
                    Err(refuse("ticket already used"))
                } else {
                    Ok(ticket)
                }
            }
        },
    };
    let ticket = match verdict {
        Ok(ticket) => ticket,
        Err(reply) => {
            if let JoinReply::Refused(reason) = &reply {
                eprintln!("[join] connection {conn}: refused ({reason})");
            }
            send.write_all(&control::frame(&realm_proto::encode_join_reply(&reply)))
                .await?;
            send.finish()?;
            let _ = send.stopped().await;
            connection.close(VarInt::from_u32(1), b"refused");
            return Ok(());
        }
    };

    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<Bytes>(OUTBOX);
    let (control_tx, mut control_rx) = tokio::sync::mpsc::channel::<Bytes>(CONTROL_QUEUE);
    let (reply_tx, reply_rx) = tokio::sync::oneshot::channel();
    let (account, character) = (ticket.account, ticket.character);
    sim.send(NetEvent::Join {
        conn,
        ticket,
        outbox: out_tx,
        control: control_tx,
        reply: reply_tx,
    })?;
    // The simulation answers every join (the coordinator's answer has its own
    // deadline there); this one only bounds a stuck peer's place in the queue.
    let left = JOIN_DEADLINE.saturating_sub(began.elapsed()) + CLAIM_MARGIN;
    let reply = tokio::time::timeout(left, reply_rx).await??;
    drop(unproven);
    let accepted = matches!(reply, JoinReply::Accepted { .. });
    match &reply {
        JoinReply::Accepted { entity, .. } => eprintln!(
            "[join] connection {conn} account {account} character {character}: joined as entity {entity}"
        ),
        JoinReply::Refused(reason) => {
            eprintln!(
                "[join] connection {conn} account {account} character {character}: refused ({reason})"
            );
        }
    }
    send.write_all(&control::frame(&realm_proto::encode_join_reply(&reply)))
        .await?;
    if !accepted {
        send.finish()?;
        let _ = send.stopped().await;
        connection.close(VarInt::from_u32(1), b"refused");
        return Ok(());
    }

    // Reliable messages are written by their own task: a client that stops
    // reading its control stream stalls only that, never its snapshots. Its
    // queue then fills and the simulation drops the client.
    let mut writer = tokio::spawn(async move {
        while let Some(bytes) = control_rx.recv().await {
            if send.write_all(&bytes).await.is_err() {
                return;
            }
        }
        // The simulation let this client go: what it was told last (an
        // eviction, the maintenance notice) reaches it before the close.
        let _ = send.finish();
        let _ = tokio::time::timeout(Duration::from_secs(1), send.stopped()).await;
    });

    let mut malformed = 0_u32;
    let mut meter = Meter::new();
    let mut chunk = [0_u8; 4096];
    let mut let_go = false;
    let mut written = false;
    loop {
        tokio::select! {
            datagram = connection.read_datagram() => {
                let Ok(bytes) = datagram else { break };
                match realm_proto::decode_inputs(&bytes) {
                    Ok(batch) => match meter.input() {
                        Ok(Some(_held)) => sim.send(NetEvent::Input { conn, batch, _held })?,
                        Ok(None) => {}
                        Err(why) => {
                            eprintln!("[net] connection {conn} character {character}: closed, {why}");
                            connection.close(VarInt::from_u32(4), why.as_bytes());
                            break;
                        }
                    },
                    Err(_) => {
                        malformed += 1;
                        if malformed > MALFORMED_LIMIT {
                            connection.close(VarInt::from_u32(2), b"malformed input");
                            break;
                        }
                    }
                }
            }
            out = out_rx.recv() => {
                // No more snapshots: the simulation let this client go too
                // (its control writer may still be draining).
                let Some(bytes) = out else {
                    let_go = true;
                    break;
                };
                let _ = connection.send_datagram(bytes);
            }
            // The writer ends when the simulation drops this connection (a
            // newer login took over, or it fell behind on reliable messages).
            _ = &mut writer => {
                let_go = true;
                written = true;
                break;
            }
            read = recv.read(&mut chunk) => {
                let Ok(Some(n)) = read else { break };
                reader.push(&chunk[..n]);
                let mut bad = false;
                let mut flood = None;
                loop {
                    match reader.next_frame() {
                        Ok(Some(frame)) => match control::decode_client(&frame) {
                            Ok(msg) => match meter.control(&msg) {
                                Ok(Some(_held)) => sim.send(NetEvent::Control { conn, msg, _held })?,
                                Ok(None) => {}
                                Err(why) => {
                                    flood = Some(why);
                                    break;
                                }
                            },
                            Err(_) => bad = true,
                        },
                        Ok(None) => break,
                        Err(_) => {
                            bad = true;
                            break;
                        }
                    }
                }
                if meter.first_drop() {
                    eprintln!("[net] connection {conn} character {character}: over its message budget, dropping");
                }
                if let Some(why) = flood {
                    eprintln!("[net] connection {conn} character {character}: closed, {why}");
                    connection.close(VarInt::from_u32(4), why.as_bytes());
                    break;
                }
                if bad {
                    connection.close(VarInt::from_u32(3), b"malformed control message");
                    break;
                }
            }
        }
    }
    // Let go by the simulation: the client reads to the end of its control
    // stream (its last message) and closes; a close from here could cut
    // that off.
    if let_go {
        if !written {
            let _ = tokio::time::timeout(Duration::from_secs(2), &mut writer).await;
        }
        let _ = tokio::time::timeout(Duration::from_secs(2), connection.closed()).await;
    }
    writer.abort();
    let why = match connection.close_reason() {
        _ if let_go => "let go by the server".to_owned(),
        Some(reason) => reason.to_string(),
        None => "closed here".to_owned(),
    };
    eprintln!("[leave] connection {conn} character {character}: {why}");
    connection.close(VarInt::from_u32(0), b"bye");
    sim.send(NetEvent::Leave { conn })?;
    Ok(())
}
