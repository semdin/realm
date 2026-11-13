//! Login tickets. The login service (Phase 7) signs a ticket after checking
//! the password; a map server only holds the public key and checks the
//! signature, so a compromised map server cannot mint logins. Development
//! tools sign tickets with a local dev key (`realm_server keygen`).
//!
//! Layout: 40 payload bytes (version, account, character, expiry, nonce)
//! followed by the 64-byte Ed25519 signature over them.

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};

pub const TICKET_LEN: usize = PAYLOAD_LEN + 64;
const PAYLOAD_LEN: usize = 40;
const TICKET_VERSION: u32 = 1;

/// Who may join, until when.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub account: u64,
    pub character: u64,
    /// Seconds since the Unix epoch after which the ticket is refused.
    pub expires_unix: u64,
    /// Random; a map server refuses a nonce it has already seen.
    pub nonce: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TicketError {
    Malformed,
    BadSignature,
    Expired,
}

impl core::fmt::Display for TicketError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(match self {
            Self::Malformed => "malformed ticket",
            Self::BadSignature => "ticket signature does not verify",
            Self::Expired => "ticket expired",
        })
    }
}

impl std::error::Error for TicketError {}

impl Ticket {
    /// A ticket with a fresh random nonce.
    pub fn new(account: u64, character: u64, expires_unix: u64) -> Result<Self, getrandom::Error> {
        Ok(Self {
            account,
            character,
            expires_unix,
            nonce: getrandom::u64()?,
        })
    }

    fn payload(&self) -> [u8; PAYLOAD_LEN] {
        let mut out = [0_u8; PAYLOAD_LEN];
        out[0..4].copy_from_slice(&TICKET_VERSION.to_le_bytes());
        out[4..12].copy_from_slice(&self.account.to_le_bytes());
        out[12..20].copy_from_slice(&self.character.to_le_bytes());
        out[20..28].copy_from_slice(&self.expires_unix.to_le_bytes());
        out[28..36].copy_from_slice(&self.nonce.to_le_bytes());
        out
    }

    #[must_use]
    pub fn sign(&self, key: &SigningKey) -> Vec<u8> {
        let payload = self.payload();
        let signature = key.sign(&payload);
        let mut out = Vec::with_capacity(TICKET_LEN);
        out.extend_from_slice(&payload);
        out.extend_from_slice(&signature.to_bytes());
        out
    }

    /// Checks the signature and the expiry against `now_unix`.
    pub fn verify(bytes: &[u8], key: &VerifyingKey, now_unix: u64) -> Result<Self, TicketError> {
        if bytes.len() != TICKET_LEN {
            return Err(TicketError::Malformed);
        }
        let (payload, signature) = bytes.split_at(PAYLOAD_LEN);
        let signature =
            Signature::from_bytes(signature.try_into().map_err(|_| TicketError::Malformed)?);
        key.verify_strict(payload, &signature)
            .map_err(|_| TicketError::BadSignature)?;
        let u64_at =
            |at: usize| u64::from_le_bytes(payload[at..at + 8].try_into().unwrap_or_default());
        if u32::from_le_bytes(payload[0..4].try_into().unwrap_or_default()) != TICKET_VERSION {
            return Err(TicketError::Malformed);
        }
        let ticket = Self {
            account: u64_at(4),
            character: u64_at(12),
            expires_unix: u64_at(20),
            nonce: u64_at(28),
        };
        if ticket.expires_unix < now_unix {
            return Err(TicketError::Expired);
        }
        Ok(ticket)
    }
}

/// A new random signing key (dev tools and the login service).
pub fn generate_key() -> Result<SigningKey, getrandom::Error> {
    let mut secret = [0_u8; 32];
    getrandom::fill(&mut secret)?;
    Ok(SigningKey::from_bytes(&secret))
}
