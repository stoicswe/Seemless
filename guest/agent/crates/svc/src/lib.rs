//! The Seemless guest service (docs/06 "Agent processes"): owns the
//! virtio-serial ports, answers the host's core requests and supervises the
//! session agent, multiplexing for it over a named pipe.
//!
//! [`router`] and [`serve`] are platform-independent and tested on the Mac;
//! [`win`] is the Windows side (ports, pipe, SCM, supervision, GuestInfo).

pub mod router;
pub mod serve;

#[cfg(windows)]
pub mod win;

pub use transport::log::{log, log_to_file};

/// The build string sent in `Hello` (at most 256 bytes). The workspace
/// version is shared by both binaries; `SEEMLESS_AGENT_REV` (set by
/// `guest/tools/build.sh`) adds the source revision.
pub fn build_string(binary: &str) -> String {
    let mut s = format!("{binary} {}", env!("CARGO_PKG_VERSION"));
    if let Some(rev) = option_env!("SEEMLESS_AGENT_REV") {
        s.push_str(&format!(" ({rev})"));
    }
    s
}
