//! realm_netem --listen 127.0.0.1:7800 --server 127.0.0.1:7777
//!             [--delay-ms 100] [--jitter-ms 20] [--loss 0.02] [--seed 1]
//!
//! Forwards UDP between one client and a server, holding every datagram for
//! `delay ± jitter` milliseconds and dropping `loss` of them, in each
//! direction (so 100 ms of delay is a 200 ms round trip).

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::net::UdpSocket;
use tokio::sync::Mutex;

struct Impairment {
    delay_ms: f64,
    jitter_ms: f64,
    loss: f64,
    rng: AtomicU64,
}

impl Impairment {
    fn unit(&self) -> f64 {
        // xorshift64, shared by both directions.
        let mut x = self.rng.load(Ordering::Relaxed);
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.rng.store(x, Ordering::Relaxed);
        (x >> 11) as f64 / (1_u64 << 53) as f64
    }

    /// None to drop, or how long to hold the datagram.
    fn hold(&self) -> Option<Duration> {
        if self.unit() < self.loss {
            return None;
        }
        let ms = (self.delay_ms + (self.unit() * 2.0 - 1.0) * self.jitter_ms).max(0.0);
        Some(Duration::from_secs_f64(ms / 1000.0))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let get = |name: &str, default: &str| -> String {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
            .unwrap_or_else(|| default.to_owned())
    };
    let listen: SocketAddr = get("--listen", "127.0.0.1:7800").parse()?;
    let server: SocketAddr = get("--server", "127.0.0.1:7777").parse()?;
    let impair = Arc::new(Impairment {
        delay_ms: get("--delay-ms", "100").parse()?,
        jitter_ms: get("--jitter-ms", "20").parse()?,
        loss: get("--loss", "0.02").parse()?,
        rng: AtomicU64::new(get("--seed", "1").parse::<u64>()?.max(1) * 0x9E37_79B9_7F4A_7C15),
    });
    let front = Arc::new(UdpSocket::bind(listen).await?);
    let back = Arc::new(UdpSocket::bind("127.0.0.1:0").await?);
    back.connect(server).await?;
    let client: Arc<Mutex<Option<SocketAddr>>> = Arc::default();
    println!(
        "[netem] {listen} <-> {server}: {} ms ± {} ms each way, {:.1}% loss",
        impair.delay_ms,
        impair.jitter_ms,
        impair.loss * 100.0
    );

    let upstream = {
        let (front, back, impair, client) =
            (front.clone(), back.clone(), impair.clone(), client.clone());
        tokio::spawn(async move {
            let mut buf = vec![0_u8; 65_536];
            loop {
                let Ok((n, from)) = front.recv_from(&mut buf).await else {
                    continue;
                };
                *client.lock().await = Some(from);
                let Some(hold) = impair.hold() else { continue };
                let (packet, back) = (buf[..n].to_vec(), back.clone());
                tokio::spawn(async move {
                    tokio::time::sleep(hold).await;
                    let _ = back.send(&packet).await;
                });
            }
        })
    };
    let downstream = tokio::spawn(async move {
        let mut buf = vec![0_u8; 65_536];
        loop {
            let Ok(n) = back.recv(&mut buf).await else {
                continue;
            };
            let Some(to) = *client.lock().await else {
                continue;
            };
            let Some(hold) = impair.hold() else { continue };
            let (packet, front) = (buf[..n].to_vec(), front.clone());
            tokio::spawn(async move {
                tokio::time::sleep(hold).await;
                let _ = front.send_to(&packet, to).await;
            });
        }
    });
    let _ = tokio::join!(upstream, downstream);
    Ok(())
}
