//! Map servers (and later the login service and the coordinator) and the
//! persistence service (`realm_persist`): one TCP stream each, framed like
//! the control stream (a u32 length, then postcard), after a hello that
//! proves the caller holds the shared service key (keys/coord.key).
//! Requests are answered in order on the stream they came on, each with its
//! `req`; a caller may have several in flight.

use realm_rules::CharacterSheet;
use serde::{Deserialize, Serialize};

/// Caller -> persistence service.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum PersistMsg {
    /// First frame: the shared service key.
    Hello { key: [u8; 32] },
    /// The stored sheet of `character` (None: never saved).
    Load { req: u64, character: u64 },
    /// Store `sheet` unless the stored copy is newer (a higher revision).
    Save {
        req: u64,
        sheet: Box<CharacterSheet>,
    },
}

/// Persistence service -> caller.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum PersistReply {
    Loaded {
        req: u64,
        /// Err: the store could not answer (the caller refuses the join).
        result: Result<Option<Box<CharacterSheet>>, String>,
    },
    /// `ok`: the sheet is stored (committed). Not ok: `error` says why
    /// ("stale": the stored revision is newer; else the store failed).
    Saved {
        req: u64,
        character: u64,
        revision: u64,
        ok: bool,
        error: String,
    },
}

pub fn encode_msg(msg: &PersistMsg) -> Vec<u8> {
    crate::control::frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

pub fn encode_reply(msg: &PersistReply) -> Vec<u8> {
    crate::control::frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

pub fn decode_msg(payload: &[u8]) -> Result<PersistMsg, crate::control::FrameError> {
    postcard::from_bytes(payload).map_err(|_| crate::control::FrameError::Malformed)
}

pub fn decode_reply(payload: &[u8]) -> Result<PersistReply, crate::control::FrameError> {
    postcard::from_bytes(payload).map_err(|_| crate::control::FrameError::Malformed)
}
