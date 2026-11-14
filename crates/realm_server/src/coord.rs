//! The map server's link to the coordinator: one TCP stream, reconnected
//! every two seconds while it is down. What arrives goes to the simulation
//! as `NetEvent::Coord`; `CoordUp` tells it to say again who is on its map.
//! While the link is down, what the simulation sends is dropped (it learns
//! through `CoordDown` and answers players itself).

use std::time::Duration;

use crossbeam_channel::Sender;
use realm_proto::control::FrameReader;
use realm_proto::coord::{MapMsg, decode_coord, encode_map};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::sim::NetEvent;

const RETRY: Duration = Duration::from_secs(2);

pub async fn link(
    addr: String,
    key: [u8; 32],
    map: String,
    address: String,
    capacity: u16,
    mut outgoing: UnboundedReceiver<MapMsg>,
    sim: Sender<NetEvent>,
) {
    let mut announced_down = false;
    loop {
        let stream = match TcpStream::connect(&addr).await {
            Ok(s) => s,
            Err(_) => {
                if !announced_down {
                    eprintln!("[coord] no coordinator at {addr}; retrying");
                    announced_down = true;
                }
                // Nothing reaches a coordinator that is not there.
                while outgoing.try_recv().is_ok() {}
                tokio::time::sleep(RETRY).await;
                continue;
            }
        };
        let _ = stream.set_nodelay(true);
        let (mut read, mut write) = stream.into_split();
        if write
            .write_all(&encode_map(&MapMsg::Hello {
                key,
                map: map.clone(),
                address: address.clone(),
                capacity,
            }))
            .await
            .is_err()
        {
            tokio::time::sleep(RETRY).await;
            continue;
        }
        println!("[coord] linked to {addr}");
        announced_down = false;
        while outgoing.try_recv().is_ok() {}
        if sim.send(NetEvent::CoordUp).is_err() {
            return;
        }
        let mut reader = FrameReader::default();
        let mut chunk = vec![0_u8; 16 * 1024];
        loop {
            tokio::select! {
                msg = outgoing.recv() => {
                    let Some(msg) = msg else { return };
                    if write.write_all(&encode_map(&msg)).await.is_err() {
                        break;
                    }
                }
                n = read.read(&mut chunk) => {
                    let Ok(n) = n else { break };
                    if n == 0 {
                        break;
                    }
                    reader.push(&chunk[..n]);
                    let mut broken = false;
                    loop {
                        match reader.next_frame() {
                            Ok(Some(frame)) => match decode_coord(&frame) {
                                Ok(msg) => {
                                    if sim.send(NetEvent::Coord(msg)).is_err() {
                                        return;
                                    }
                                }
                                Err(_) => { broken = true; break; }
                            },
                            Ok(None) => break,
                            Err(_) => { broken = true; break; }
                        }
                    }
                    if broken {
                        break;
                    }
                }
            }
        }
        eprintln!("[coord] link to {addr} lost; retrying");
        if sim.send(NetEvent::CoordDown).is_err() {
            return;
        }
        tokio::time::sleep(RETRY).await;
    }
}
