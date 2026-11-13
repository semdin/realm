//! Wire protocol. Client and server are built from the same commit, so the
//! version only guards against an old installed client talking to a new
//! server; it never has to be bumped by hand for drift between repositories.

/// Bumped whenever a message layout changes.
pub const PROTOCOL_VERSION: u16 = 1;

/// QUIC application protocol name, checked during the TLS handshake.
pub const ALPN: &[u8] = b"realm/1";
