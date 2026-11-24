//! Protocol types generated from /proto, framing and version negotiation (docs/06).
//!
//! - [`v1`]: the prost types for `seemless.v1` (`Envelope` and everything in it).
//! - [`frame`]: `u32 length (LE) | u8 kind | payload` framing with per-channel caps.
//! - [`handshake`]: `Hello` validation and capability negotiation.
//!
//! Everything here is platform-independent and tested on the Mac.

pub mod frame;
pub mod handshake;

/// Generated from `proto/seemless.proto`.
#[allow(clippy::all, missing_docs)]
pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/seemless.v1.rs"));
}

pub use prost::Message;

use v1::envelope::Body;

impl v1::Envelope {
    /// An event or request: `reply_to` is 0.
    pub fn new(seq: u64, body: Body) -> Self {
        Self { seq, reply_to: 0, body: Some(body) }
    }

    /// A response to the request with sequence number `request`.
    pub fn reply(seq: u64, request: u64, body: Body) -> Self {
        Self { seq, reply_to: request, body: Some(body) }
    }

    /// Encodes as a complete control-channel frame.
    pub fn to_frame(&self) -> Vec<u8> {
        frame::encode(frame::Kind::Envelope, &self.encode_to_vec())
    }
}

#[cfg(test)]
mod golden;
