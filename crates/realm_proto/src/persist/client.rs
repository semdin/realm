//! The persistence service from a tokio service (the login service, the
//! coordinator): one task owns the stream and answers requests one at a
//! time, in the order they were made. The link opens on first use and again
//! after any failure.
//!
//! [`PersistClient::call`] tries once and hands back what came of it (a
//! login answers "try later" on a failure). [`PersistClient::keep`] is for
//! changes nobody waits on (a board, a GA): it is tried until it lands,
//! and what was asked after it waits behind it, so changes land in order.
//! [`PersistClient::call_until_answered`] is a call tried until the store
//! answers (loading at start); dropping its future gives it up.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};

use super::{PersistMsg, PersistReply, decode_reply, encode_msg};
use crate::control::FrameReader;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const ANSWER_TIMEOUT: Duration = Duration::from_secs(15);
const RETRY_EVERY: Duration = Duration::from_secs(1);

struct Job {
    msg: PersistMsg,
    /// Tried again until it lands.
    retry: bool,
    reply: Option<oneshot::Sender<Result<PersistReply, String>>>,
}

pub struct PersistClient {
    jobs: mpsc::UnboundedSender<Job>,
    next: AtomicU64,
}

impl PersistClient {
    /// Starts the client's task (inside a tokio runtime).
    pub fn start(addr: String, key: [u8; 32]) -> Arc<Self> {
        let (jobs, queue) = mpsc::unbounded_channel();
        tokio::spawn(run(addr, key, queue));
        Arc::new(Self {
            jobs,
            next: AtomicU64::new(1),
        })
    }

    fn job(
        &self,
        make: impl FnOnce(u64) -> PersistMsg,
        retry: bool,
        reply: Option<oneshot::Sender<Result<PersistReply, String>>>,
    ) -> bool {
        let msg = make(self.next.fetch_add(1, Ordering::Relaxed));
        self.jobs.send(Job { msg, retry, reply }).is_ok()
    }

    /// One try: the service's answer, or why there was none.
    pub async fn call(&self, make: impl FnOnce(u64) -> PersistMsg) -> Result<PersistReply, String> {
        let (tx, rx) = oneshot::channel();
        if !self.job(make, false, Some(tx)) {
            return Err("the persistence client stopped".to_owned());
        }
        rx.await
            .map_err(|_| "the persistence client stopped".to_owned())?
    }

    /// Tried until the service answers without an error.
    pub async fn call_until_answered(
        &self,
        make: impl FnOnce(u64) -> PersistMsg,
    ) -> Result<PersistReply, String> {
        let (tx, rx) = oneshot::channel();
        if !self.job(make, true, Some(tx)) {
            return Err("the persistence client stopped".to_owned());
        }
        rx.await
            .map_err(|_| "the persistence client stopped".to_owned())?
    }

    /// A change nobody waits on: tried until it lands, in order.
    pub fn keep(&self, make: impl FnOnce(u64) -> PersistMsg) {
        if !self.job(make, true, None) {
            eprintln!("[persist] the persistence client stopped: a change is lost");
        }
    }
}

type Link = (TcpStream, FrameReader);

async fn open(addr: &str, key: [u8; 32]) -> Result<Link, String> {
    let mut stream = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr))
        .await
        .map_err(|_| format!("persist {addr}: no answer"))?
        .map_err(|e| format!("persist {addr}: {e}"))?;
    stream.set_nodelay(true).ok();
    stream
        .write_all(&encode_msg(&PersistMsg::Hello { key }))
        .await
        .map_err(|e| format!("persist hello: {e}"))?;
    Ok((stream, FrameReader::default()))
}

async fn exchange(link: &mut Link, msg: &PersistMsg) -> Result<PersistReply, String> {
    let (stream, reader) = link;
    stream
        .write_all(&encode_msg(msg))
        .await
        .map_err(|e| e.to_string())?;
    let mut chunk = vec![0_u8; 64 * 1024];
    let answer = async {
        loop {
            if let Some(frame) = reader.next_frame().map_err(|e| e.to_string())? {
                return decode_reply(&frame).map_err(|e| e.to_string());
            }
            let n = stream.read(&mut chunk).await.map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("the persistence service closed the link".to_owned());
            }
            reader.push(&chunk[..n]);
        }
    };
    let reply = tokio::time::timeout(ANSWER_TIMEOUT, answer)
        .await
        .map_err(|_| "the persistence service did not answer".to_owned())??;
    if reply.req() != msg.req() {
        return Err(format!(
            "the persistence service answered {} to {}",
            reply.req(),
            msg.req()
        ));
    }
    Ok(reply)
}

async fn attempt(
    addr: &str,
    key: [u8; 32],
    link: &mut Option<Link>,
    msg: &PersistMsg,
) -> Result<PersistReply, String> {
    if link.is_none() {
        *link = Some(open(addr, key).await?);
    }
    let Some(open_link) = link.as_mut() else {
        return Err("no link".to_owned());
    };
    let result = exchange(open_link, msg).await;
    if result.is_err() {
        // A fresh link next time.
        *link = None;
    }
    result
}

async fn run(addr: String, key: [u8; 32], mut queue: mpsc::UnboundedReceiver<Job>) {
    let mut link: Option<Link> = None;
    while let Some(job) = queue.recv().await {
        let mut failures = 0_u32;
        loop {
            let result = attempt(&addr, key, &mut link, &job.msg).await;
            let failed = match &result {
                Err(e) => Some(e.clone()),
                Ok(reply) => reply.error().map(str::to_owned),
            };
            let given_up = job.reply.as_ref().is_some_and(oneshot::Sender::is_closed);
            match failed {
                Some(e) if job.retry && !given_up => {
                    if failures.is_multiple_of(30) {
                        eprintln!("[persist] request {}: {e} (trying again)", job.msg.req());
                    }
                    failures += 1;
                    tokio::time::sleep(RETRY_EVERY).await;
                }
                failed => {
                    if failures > 0 && failed.is_none() {
                        eprintln!("[persist] request {} landed", job.msg.req());
                    }
                    if let Some(tx) = job.reply {
                        let _ = tx.send(result);
                    }
                    break;
                }
            }
        }
    }
}
