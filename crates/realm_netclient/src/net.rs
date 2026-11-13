//! The client's connection: a QUIC session on a background thread, talked
//! to through two channels so the game's main thread never waits on the
//! network. `connect` returns at once; the join result arrives as an event.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, TryRecvError, channel};
use std::time::Duration;

use quinn::crypto::rustls::QuicClientConfig;
use quinn::{ClientConfig, Endpoint};
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
    Closed(String),
}

pub struct NetHandle {
    events: Receiver<NetEvent>,
    outgoing: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    _runtime: tokio::runtime::Runtime,
}

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
                send.write_all(&realm_proto::encode_hello(&Hello {
                    protocol: PROTOCOL_VERSION,
                    ticket,
                }))
                .await
                .map_err(|e| e.to_string())?;
                send.finish().map_err(|e| e.to_string())?;
                let reply = recv.read_to_end(1024).await.map_err(|e| e.to_string())?;
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
                loop {
                    tokio::select! {
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
                    }
                }
            };
            let result: Result<(), String> = run.await;
            let _ = event_tx.send(NetEvent::Closed(
                result.err().unwrap_or_else(|| "closed".to_owned()),
            ));
        });
        Ok(Self {
            events,
            outgoing,
            _runtime: runtime,
        })
    }

    pub fn send(&self, bytes: Vec<u8>) {
        let _ = self.outgoing.send(bytes);
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
