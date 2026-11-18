//! The client's connection: a QUIC session on a background thread, talked
//! to through channels so the game's main thread never waits on the network.
//! `connect` returns at once; the join result arrives as an event. After the
//! join the join stream carries control messages both ways.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, TryRecvError, channel};
use std::time::Duration;

use quinn::crypto::rustls::QuicClientConfig;
use quinn::{ClientConfig, Endpoint};
use realm_proto::control::{self, ClientMsg, FrameReader, ServerMsg};
use realm_proto::{Hello, JoinReply, PROTOCOL_VERSION};
use rustls::pki_types::CertificateDer;

pub enum NetEvent {
    Joined {
        entity: u32,
        tick: u32,
        content_hash: [u8; 32],
        /// The dungeon copy (0: none).
        copy: u8,
    },
    Refused(String),
    Datagram(Vec<u8>),
    Control(ServerMsg),
    Closed(String),
}

pub struct NetHandle {
    events: Receiver<NetEvent>,
    outgoing: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    control: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    done: Option<tokio::sync::oneshot::Receiver<()>>,
    runtime: tokio::runtime::Runtime,
    /// `Closed` was handed out.
    ended: std::sync::atomic::AtomicBool,
    /// The connection's smoothed round trip in ms (0 until known).
    rtt_ms: Arc<std::sync::atomic::AtomicU32>,
}

/// How long dropping the handle waits for the server to hear the goodbye.
const CLOSE_WAIT: Duration = Duration::from_millis(500);
/// A handshake not done in this long starts again on a new socket.
const HANDSHAKE_TRY: Duration = Duration::from_secs(4);
/// That many handshakes before the join reports "timed out".
const HANDSHAKE_TRIES: u32 = 4;

impl NetHandle {
    /// Connects to `server` (`name` is the TLS server name), trusting only
    /// `server_cert_der`, and joins with the signed `ticket`.
    pub fn connect(
        server: SocketAddr,
        name: &str,
        server_cert_der: Vec<u8>,
        ticket: Vec<u8>,
    ) -> Result<Self, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut roots = rustls::RootCertStore::empty();
        roots
            .add(CertificateDer::from(server_cert_der))
            .map_err(|e| e.to_string())?;
        let mut tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        tls.alpn_protocols = vec![realm_proto::ALPN.to_vec()];
        let mut config = ClientConfig::new(Arc::new(
            QuicClientConfig::try_from(tls).map_err(|e| e.to_string())?,
        ));
        let mut transport = quinn::TransportConfig::default();
        transport.keep_alive_interval(Some(Duration::from_secs(2)));
        transport.max_idle_timeout(Some(quinn::VarInt::from_u32(10_000).into()));
        config.transport_config(Arc::new(transport));

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let (event_tx, events) = channel();
        let (outgoing, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let (control_tx, mut control_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        let (shutdown, mut shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let (done_tx, done) = tokio::sync::oneshot::channel::<()>();
        let name = name.to_owned();
        let rtt_ms = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let rtt_out = rtt_ms.clone();
        runtime.spawn(async move {
            let run = async {
                // Some paths drop a whole UDP flow (a source port) - seen live
                // through a zero-trust network agent: not one packet of a
                // handshake reached the server, while the next socket got
                // through at once. Resending on the same socket cannot help,
                // so a handshake that is not done in HANDSHAKE_TRY starts
                // again on a new socket (a new source port), HANDSHAKE_TRIES
                // times. The ticket is only sent after the handshake.
                let mut tries = 0;
                let (endpoint, connection) = loop {
                    tries += 1;
                    let mut endpoint =
                        Endpoint::client("0.0.0.0:0".parse().map_err(|e| format!("{e}"))?)
                            .map_err(|e| e.to_string())?;
                    endpoint.set_default_client_config(config.clone());
                    let connecting = endpoint
                        .connect(server, &name)
                        .map_err(|e| e.to_string())?;
                    match tokio::time::timeout(HANDSHAKE_TRY, connecting).await {
                        Ok(done) => break (endpoint, done.map_err(|e| e.to_string())?),
                        Err(_) if tries < HANDSHAKE_TRIES => {
                            endpoint.close(quinn::VarInt::from_u32(0), b"retry");
                        }
                        Err(_) => return Err("timed out".to_owned()),
                    }
                };
                let (mut send, mut recv) = connection.open_bi().await.map_err(|e| e.to_string())?;
                send.write_all(&control::frame(&realm_proto::encode_hello(&Hello {
                    protocol: PROTOCOL_VERSION,
                    ticket,
                })))
                .await
                .map_err(|e| e.to_string())?;
                let mut reader = FrameReader::default();
                let mut chunk = [0_u8; 4096];
                let reply = loop {
                    if let Some(frame) = reader.next_frame().map_err(|e| e.to_string())? {
                        break frame;
                    }
                    let n = recv
                        .read(&mut chunk)
                        .await
                        .map_err(|e| e.to_string())?
                        .ok_or("join stream closed")?;
                    reader.push(&chunk[..n]);
                };
                match realm_proto::decode_join_reply(&reply).map_err(|e| e.to_string())? {
                    JoinReply::Accepted {
                        entity,
                        tick,
                        content_hash,
                        copy,
                    } => {
                        let _ = event_tx.send(NetEvent::Joined {
                            entity,
                            tick,
                            content_hash,
                            copy,
                        });
                    }
                    JoinReply::Refused(reason) => {
                        let _ = event_tx.send(NetEvent::Refused(reason));
                        return Ok(());
                    }
                }
                // Frames that arrived together with the join reply.
                while let Some(frame) = reader.next_frame().map_err(|e| e.to_string())? {
                    let msg = control::decode_server(&frame).map_err(|e| e.to_string())?;
                    if event_tx.send(NetEvent::Control(msg)).is_err() {
                        return Ok(());
                    }
                }
                // Control messages are written by their own task so a slow
                // stream never holds up datagrams.
                tokio::spawn(async move {
                    while let Some(bytes) = control_rx.recv().await {
                        if send.write_all(&bytes).await.is_err() {
                            break;
                        }
                    }
                });
                let mut every = tokio::time::interval(Duration::from_millis(500));
                loop {
                    tokio::select! {
                        _ = every.tick() => {
                            let ms = connection.rtt().as_millis().min(u128::from(u32::MAX)) as u32;
                            rtt_out.store(ms, std::sync::atomic::Ordering::Relaxed);
                        }
                        _ = &mut shutdown_rx => {
                            // A clean goodbye: the server sees the player leave
                            // (and saves it) now, not after the idle timeout.
                            connection.close(quinn::VarInt::from_u32(0), b"bye");
                            let _ = tokio::time::timeout(CLOSE_WAIT, endpoint.wait_idle()).await;
                            return Ok(());
                        }
                        datagram = connection.read_datagram() => {
                            let bytes = datagram.map_err(|e| e.to_string())?;
                            if event_tx.send(NetEvent::Datagram(bytes.to_vec())).is_err() {
                                return Ok(());
                            }
                        }
                        out = out_rx.recv() => {
                            let Some(bytes) = out else { return Ok(()) };
                            let _ = connection.send_datagram(bytes.into());
                        }
                        read = recv.read(&mut chunk) => {
                            // A read error only says "connection lost"; which
                            // branch wakes first is chance, so the reason comes
                            // from the connection itself.
                            let n = read
                                .map_err(|e| {
                                    connection
                                        .close_reason()
                                        .map_or_else(|| e.to_string(), |why| why.to_string())
                                })?
                                .ok_or("closed by the server")?;
                            reader.push(&chunk[..n]);
                            while let Some(frame) = reader.next_frame().map_err(|e| e.to_string())? {
                                let msg = control::decode_server(&frame).map_err(|e| e.to_string())?;
                                if event_tx.send(NetEvent::Control(msg)).is_err() {
                                    return Ok(());
                                }
                            }
                        }
                    }
                }
            };
            let result: Result<(), String> = run.await;
            let _ = event_tx.send(NetEvent::Closed(
                result.err().unwrap_or_else(|| "closed".to_owned()),
            ));
            let _ = done_tx.send(());
        });
        Ok(Self {
            events,
            outgoing,
            control: control_tx,
            shutdown: Some(shutdown),
            done: Some(done),
            runtime,
            ended: std::sync::atomic::AtomicBool::new(false),
            rtt_ms,
        })
    }

    /// The connection's smoothed round trip in milliseconds (QUIC's own
    /// estimate, from every acknowledged packet; 0 until known).
    pub fn rtt_ms(&self) -> u32 {
        self.rtt_ms.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// An unreliable datagram (an input packet).
    pub fn send(&self, bytes: Vec<u8>) {
        let _ = self.outgoing.send(bytes);
    }

    /// A reliable, ordered control message.
    pub fn send_control(&self, msg: &ClientMsg) {
        let _ = self.control.send(control::encode_client(msg));
    }

    /// The next event, if one is waiting. The connection's end comes once
    /// (`Closed`); after it, nothing.
    pub fn poll(&self) -> Option<NetEvent> {
        if self.ended.load(std::sync::atomic::Ordering::Relaxed) {
            return None;
        }
        let event = match self.events.try_recv() {
            Ok(event) => event,
            Err(TryRecvError::Empty) => return None,
            // The network thread always says Closed before it ends; one
            // that died without saying it is closed all the same.
            Err(TryRecvError::Disconnected) => NetEvent::Closed("network thread ended".to_owned()),
        };
        if matches!(event, NetEvent::Closed(_)) {
            self.ended.store(true, std::sync::atomic::Ordering::Relaxed);
        }
        Some(event)
    }
}

impl Drop for NetHandle {
    /// Closes the connection properly before the network thread stops.
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(done) = self.done.take() {
            let _ = self
                .runtime
                .block_on(async { tokio::time::timeout(CLOSE_WAIT * 2, done).await });
        }
    }
}
