//! `Hello` exchange (docs/06 "Handshake").
//!
//! Both sides send `Hello` first. A major-version mismatch ends the session
//! (the host then offers to update guest tools); minor versions only inform.
//! Features are used only when both sides list their capability string.
//!
//! The same rules are implemented in Swift (`AgentHandshake`); the shared
//! golden frames in `proto/testdata` keep the encodings identical.

use std::fmt;

use crate::v1::{Hello, Role};

pub const PROTOCOL_MAJOR: u32 = 1;
pub const PROTOCOL_MINOR: u32 = 0;

/// Limits on what a peer may put in its `Hello` (the guest is untrusted).
pub const MAX_BUILD_BYTES: usize = 256;
pub const MAX_CAPABILITIES: usize = 64;
pub const MAX_CAPABILITY_BYTES: usize = 64;

/// Capability strings. Each names a message family and its version.
pub mod capability {
    /// Hello, Ping/Pong, Error/Ack, GetGuestInfo/GuestInfo, SessionState.
    pub const CORE: &str = "core.v1";
    pub const SYSTEM: &str = "system.v1";
    pub const WINDOWS: &str = "windows.v1";
    pub const APPS: &str = "apps.v1";
    pub const CLIPBOARD: &str = "clipboard.v1";
    pub const DRAG_DROP: &str = "dragdrop.v1";
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Negotiated {
    pub peer_major: u32,
    pub peer_minor: u32,
    pub peer_build: String,
    pub peer_role: Role,
    /// Capabilities both sides listed, sorted.
    pub capabilities: Vec<String>,
}

impl Negotiated {
    pub fn has(&self, capability: &str) -> bool {
        self.capabilities.binary_search_by(|c| c.as_str().cmp(capability)).is_ok()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HandshakeError {
    MajorMismatch { local: u32, remote: u32 },
    WrongRole(i32),
    Invalid(String),
}

impl fmt::Display for HandshakeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HandshakeError::MajorMismatch { local, remote } => {
                write!(f, "protocol {remote}.x is not compatible with {local}.x")
            }
            HandshakeError::WrongRole(r) => write!(f, "peer has the wrong role ({r})"),
            HandshakeError::Invalid(why) => write!(f, "invalid Hello: {why}"),
        }
    }
}

impl std::error::Error for HandshakeError {}

pub fn hello(role: Role, build: &str, capabilities: &[&str]) -> Hello {
    Hello {
        protocol_major: PROTOCOL_MAJOR,
        protocol_minor: PROTOCOL_MINOR,
        build: build.to_owned(),
        capabilities: capabilities.iter().map(|c| (*c).to_owned()).collect(),
        role: role as i32,
    }
}

fn valid_capability(c: &str) -> bool {
    !c.is_empty()
        && c.len() <= MAX_CAPABILITY_BYTES
        && c.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'_' || b == b'-')
}

/// Checks `remote` against `local` and returns what the session may use.
pub fn negotiate(local: &Hello, remote: &Hello) -> Result<Negotiated, HandshakeError> {
    if remote.build.len() > MAX_BUILD_BYTES {
        return Err(HandshakeError::Invalid("build string too long".into()));
    }
    if remote.capabilities.len() > MAX_CAPABILITIES {
        return Err(HandshakeError::Invalid("too many capabilities".into()));
    }
    if let Some(bad) = remote.capabilities.iter().find(|c| !valid_capability(c)) {
        return Err(HandshakeError::Invalid(format!("bad capability {:?}", bad.chars().take(80).collect::<String>())));
    }
    let expected = match Role::try_from(local.role) {
        Ok(Role::Host) => Role::GuestService,
        Ok(Role::GuestService) => Role::Host,
        _ => return Err(HandshakeError::Invalid("local role unspecified".into())),
    };
    let peer_role = Role::try_from(remote.role).map_err(|_| HandshakeError::WrongRole(remote.role))?;
    if peer_role != expected {
        return Err(HandshakeError::WrongRole(remote.role));
    }
    if remote.protocol_major != local.protocol_major {
        return Err(HandshakeError::MajorMismatch { local: local.protocol_major, remote: remote.protocol_major });
    }
    let mut capabilities: Vec<String> =
        local.capabilities.iter().filter(|c| remote.capabilities.contains(c)).cloned().collect();
    capabilities.sort();
    capabilities.dedup();
    Ok(Negotiated {
        peer_major: remote.protocol_major,
        peer_minor: remote.protocol_minor,
        peer_build: remote.build.clone(),
        peer_role,
        capabilities,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host() -> Hello {
        hello(Role::Host, "host", &[capability::CORE, capability::WINDOWS, capability::CLIPBOARD])
    }

    #[test]
    fn intersects_capabilities() {
        let guest = hello(Role::GuestService, "agent 0.0.1", &[capability::WINDOWS, capability::CORE, "future.v9"]);
        let n = negotiate(&host(), &guest).unwrap();
        assert_eq!(n.capabilities, ["core.v1", "windows.v1"]);
        assert!(n.has(capability::WINDOWS));
        assert!(!n.has(capability::CLIPBOARD));
        assert_eq!(n.peer_build, "agent 0.0.1");
    }

    #[test]
    fn minor_differences_are_fine_major_is_not() {
        let mut guest = hello(Role::GuestService, "g", &[capability::CORE]);
        guest.protocol_minor = 7;
        assert_eq!(negotiate(&host(), &guest).unwrap().peer_minor, 7);
        guest.protocol_major = 2;
        assert_eq!(negotiate(&host(), &guest), Err(HandshakeError::MajorMismatch { local: 1, remote: 2 }));
    }

    #[test]
    fn rejects_bad_hellos() {
        let same_role = hello(Role::Host, "g", &[]);
        assert_eq!(negotiate(&host(), &same_role), Err(HandshakeError::WrongRole(Role::Host as i32)));
        let mut unknown = hello(Role::GuestService, "g", &[]);
        unknown.role = 99;
        assert_eq!(negotiate(&host(), &unknown), Err(HandshakeError::WrongRole(99)));
        let long = hello(Role::GuestService, &"x".repeat(MAX_BUILD_BYTES + 1), &[]);
        assert!(matches!(negotiate(&host(), &long), Err(HandshakeError::Invalid(_))));
        let upper = hello(Role::GuestService, "g", &["Core.v1"]);
        assert!(matches!(negotiate(&host(), &upper), Err(HandshakeError::Invalid(_))));
        let many: Vec<String> = (0..=MAX_CAPABILITIES).map(|i| format!("c{i}")).collect();
        let many: Vec<&str> = many.iter().map(String::as_str).collect();
        assert!(matches!(negotiate(&host(), &hello(Role::GuestService, "g", &many)), Err(HandshakeError::Invalid(_))));
    }
}
