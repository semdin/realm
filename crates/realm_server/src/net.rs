//! QUIC side of the map server. Each connection: a join stream (a Hello frame
//! with a signed ticket -> a JoinReply frame) that then stays open as the
//! control channel (framed messages both ways), inputs in and snapshots out as
//! datagrams. Nothing here touches game state; it forwards to the simulation
//! thread and writes what it gets back.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use crossbeam_channel::Sender;
use quinn::crypto::rustls::QuicServerConfig;
use quinn::{Endpoint, ServerConfig, TransportConfig, VarInt};
use realm_proto::control::{self, FrameReader};
use realm_proto::ticket::Ticket;
use realm_proto::{JoinReply, PROTOCOL_VERSION, VerifyingKey};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

use crate::selfcheck::AnyResult;
use crate::sim::{CONTROL_QUEUE, ConnId, NetEvent};

/// Malformed datagrams a connection may send before it is closed.
const MALFORMED_LIMIT: u32 = 50;
/// Snapshots waiting for a slow connection; older ones are dropped (the next
/// snapshot supersedes them anyway).
const OUTBOX: usize = 4;

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
    Ok(Endpoint::server(config, bind.parse()?)?)
}

/// Seen ticket nonces until their expiry: a ticket joins once.
type Nonces = Arc<Mutex<HashMap<u64, u64>>>;

pub async fn accept_loop(endpoint: Endpoint, sim: Sender<NetEvent>, key: VerifyingKey) {
    let nonces: Nonces = Arc::default();
    let mut next_conn: ConnId = 1;
    while let Some(incoming) = endpoint.accept().await {
        let conn = next_conn;
        next_conn += 1;
        let (sim, nonces) = (sim.clone(), nonces.clone());
        tokio::spawn(async move {
            if let Err(error) = connection(incoming, conn, sim, key, nonces).await {
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
) -> AnyResult<()> {
    let connection = incoming.await?;
    let (mut send, mut recv) =
        tokio::time::timeout(Duration::from_secs(5), connection.accept_bi()).await??;
    let mut reader = FrameReader::default();
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
    sim.send(NetEvent::Join {
        conn,
        ticket,
        outbox: out_tx,
        control: control_tx,
        reply: reply_tx,
    })?;
    let reply = reply_rx.await?;
    let accepted = matches!(reply, JoinReply::Accepted { .. });
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
                break;
            }
        }
    });

    let mut malformed = 0_u32;
    let mut chunk = [0_u8; 4096];
    loop {
        tokio::select! {
            datagram = connection.read_datagram() => {
                let Ok(bytes) = datagram else { break };
                match realm_proto::decode_inputs(&bytes) {
                    Ok(batch) => sim.send(NetEvent::Input { conn, batch })?,
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
                let Some(bytes) = out else { break };
                let _ = connection.send_datagram(bytes);
            }
            // The writer ends when the simulation drops this connection (a
            // newer login took over, or it fell behind on reliable messages).
            _ = &mut writer => break,
            read = recv.read(&mut chunk) => {
                let Ok(Some(n)) = read else { break };
                reader.push(&chunk[..n]);
                let mut bad = false;
                loop {
                    match reader.next_frame() {
                        Ok(Some(frame)) => match control::decode_client(&frame) {
                            Ok(msg) => sim.send(NetEvent::Control { conn, msg })?,
                            Err(_) => bad = true,
                        },
                        Ok(None) => break,
                        Err(_) => {
                            bad = true;
                            break;
                        }
                    }
                }
                if bad {
                    connection.close(VarInt::from_u32(3), b"malformed control message");
                    break;
                }
            }
        }
    }
    writer.abort();
    connection.close(VarInt::from_u32(0), b"bye");
    sim.send(NetEvent::Leave { conn })?;
    Ok(())
}
