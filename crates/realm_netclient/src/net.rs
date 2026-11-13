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
}

/// How long dropping the handle waits for the server to hear the goodbye.
const CLOSE_WAIT: Duration = Duration::from_millis(500);

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
        runtime.spawn(async move {
            let run = async {
                let mut endpoint =
                    Endpoint::client("0.0.0.0:0".parse().map_err(|e| format!("{e}"))?)
                        .map_err(|e| e.to_string())?;
                endpoint.set_default_client_config(config);
                let connection = endpoint
                    .connect(server, &name)
                    .map_err(|e| e.to_string())?
                    .await
                    .map_err(|e| e.to_string())?;
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
                    } => {
                        let _ = event_tx.send(NetEvent::Joined {
                            entity,
                            tick,
                            content_hash,
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
                loop {
                    tokio::select! {
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
                            let n = read.map_err(|e| e.to_string())?.ok_or("control stream closed")?;
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
        })
    }

    /// An unreliable datagram (an input packet).
    pub fn send(&self, bytes: Vec<u8>) {
        let _ = self.outgoing.send(bytes);
    }

    /// A reliable, ordered control message.
    pub fn send_control(&self, msg: &ClientMsg) {
        let _ = self.control.send(control::encode_client(msg));
    }

    /// The next event, if one is waiting.
    pub fn poll(&self) -> Option<NetEvent> {
        match self.events.try_recv() {
            Ok(event) => Some(event),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => {
                Some(NetEvent::Closed("network thread ended".to_owned()))
            }
        }
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
