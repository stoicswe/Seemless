//! Framing (docs/06 "Transport and framing").
//!
//! A frame is `u32 length (little endian) | u8 kind | payload`, where
//! `length` is the payload length (the kind byte is not counted). Kind 0 is
//! a Protobuf `Envelope`; kind 1 is a raw bulk chunk and only valid on the
//! bulk port. A receiver that sees an oversized or malformed frame resets the
//! channel: [`Decoder`] stops accepting bytes after its first error.

use std::fmt;

/// Header bytes before the payload.
pub const HEADER_LEN: usize = 5;
/// Largest payload on the control port.
pub const MAX_CONTROL_PAYLOAD: usize = 1 << 20;
/// Largest payload on the bulk port.
pub const MAX_BULK_PAYLOAD: usize = 4 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    Envelope = 0,
    Bulk = 1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channel {
    Control,
    Bulk,
}

impl Channel {
    pub fn max_payload(self) -> usize {
        match self {
            Channel::Control => MAX_CONTROL_PAYLOAD,
            Channel::Bulk => MAX_BULK_PAYLOAD,
        }
    }

    fn allows(self, kind: Kind) -> bool {
        matches!((self, kind), (_, Kind::Envelope) | (Channel::Bulk, Kind::Bulk))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub kind: Kind,
    pub payload: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FrameError {
    Oversized { length: usize, max: usize },
    UnknownKind(u8),
    KindNotAllowed { kind: Kind, channel: Channel },
    /// A previous error already poisoned this decoder.
    Reset,
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FrameError::Oversized { length, max } => write!(f, "frame of {length} bytes exceeds {max}"),
            FrameError::UnknownKind(k) => write!(f, "unknown frame kind {k}"),
            FrameError::KindNotAllowed { kind, channel } => write!(f, "{kind:?} frame not allowed on {channel:?} channel"),
            FrameError::Reset => write!(f, "channel must be reset after a framing error"),
        }
    }
}

impl std::error::Error for FrameError {}

/// Encodes one frame. Panics if `payload` exceeds `u32::MAX` (callers stay
/// far below the channel caps).
pub fn encode(kind: Kind, payload: &[u8]) -> Vec<u8> {
    let length = u32::try_from(payload.len()).expect("frame payload fits u32");
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&length.to_le_bytes());
    out.push(kind as u8);
    out.extend_from_slice(payload);
    out
}

/// Incremental decoder: feed it whatever the port delivered, take whole frames.
#[derive(Debug)]
pub struct Decoder {
    channel: Channel,
    buffer: Vec<u8>,
    failed: bool,
}

impl Decoder {
    pub fn new(channel: Channel) -> Self {
        Self { channel, buffer: Vec::new(), failed: false }
    }

    /// Appends `bytes` and returns every frame now complete, plus the error
    /// that stopped decoding, if any. Frames before a bad one are still the
    /// peer's real messages and are returned. The header is checked as soon
    /// as it is in, so an oversized length fails before its payload is
    /// buffered. After an error every later call reports `Reset`.
    pub fn decode(&mut self, bytes: &[u8]) -> (Vec<Frame>, Option<FrameError>) {
        if self.failed {
            return (Vec::new(), Some(FrameError::Reset));
        }
        self.buffer.extend_from_slice(bytes);
        let mut frames = Vec::new();
        loop {
            match self.next_frame() {
                Ok(Some(frame)) => frames.push(frame),
                Ok(None) => return (frames, None),
                Err(e) => {
                    self.failed = true;
                    self.buffer.clear();
                    return (frames, Some(e));
                }
            }
        }
    }

    /// `decode`, failing on error (frames before the error are dropped).
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Frame>, FrameError> {
        match self.decode(bytes) {
            (_, Some(e)) => Err(e),
            (frames, None) => Ok(frames),
        }
    }

    /// Bytes of an incomplete frame still waiting for the rest.
    pub fn buffered(&self) -> usize {
        self.buffer.len()
    }

    fn next_frame(&mut self) -> Result<Option<Frame>, FrameError> {
        if self.buffer.len() < HEADER_LEN {
            return Ok(None);
        }
        let length = u32::from_le_bytes(self.buffer[0..4].try_into().unwrap()) as usize;
        let max = self.channel.max_payload();
        if length > max {
            return Err(FrameError::Oversized { length, max });
        }
        let kind = match self.buffer[4] {
            0 => Kind::Envelope,
            1 => Kind::Bulk,
            k => return Err(FrameError::UnknownKind(k)),
        };
        if !self.channel.allows(kind) {
            return Err(FrameError::KindNotAllowed { kind, channel: self.channel });
        }
        if self.buffer.len() < HEADER_LEN + length {
            return Ok(None);
        }
        let payload = self.buffer[HEADER_LEN..HEADER_LEN + length].to_vec();
        self.buffer.drain(..HEADER_LEN + length);
        Ok(Some(Frame { kind, payload }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_split_at_every_byte() {
        let mut wire = encode(Kind::Envelope, b"hello");
        wire.extend(encode(Kind::Envelope, b""));
        wire.extend(encode(Kind::Envelope, &[7; 300]));
        for split in 0..=wire.len() {
            let mut d = Decoder::new(Channel::Control);
            let mut frames = d.push(&wire[..split]).unwrap();
            frames.extend(d.push(&wire[split..]).unwrap());
            assert_eq!(frames.len(), 3, "split at {split}");
            assert_eq!(frames[0].payload, b"hello");
            assert!(frames[1].payload.is_empty());
            assert_eq!(frames[2].payload, vec![7; 300]);
            assert_eq!(d.buffered(), 0);
        }
    }

    #[test]
    fn header_is_little_endian_payload_length() {
        assert_eq!(encode(Kind::Bulk, b"abc"), [3, 0, 0, 0, 1, b'a', b'b', b'c']);
    }

    #[test]
    fn oversized_fails_on_header_and_poisons() {
        let mut d = Decoder::new(Channel::Control);
        let header = ((MAX_CONTROL_PAYLOAD + 1) as u32).to_le_bytes();
        let err = d.push(&[header[0], header[1], header[2], header[3], 0]).unwrap_err();
        assert_eq!(err, FrameError::Oversized { length: MAX_CONTROL_PAYLOAD + 1, max: MAX_CONTROL_PAYLOAD });
        assert_eq!(d.push(&encode(Kind::Envelope, b"x")), Err(FrameError::Reset));
    }

    #[test]
    fn frames_before_a_bad_one_are_kept() {
        let mut wire = encode(Kind::Envelope, b"good");
        wire.extend([0, 0, 0, 0, 9]);
        let mut d = Decoder::new(Channel::Control);
        let (frames, error) = d.decode(&wire);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].payload, b"good");
        assert_eq!(error, Some(FrameError::UnknownKind(9)));
    }

    #[test]
    fn bulk_limit_is_larger_and_bulk_kind_is_bulk_only() {
        let mut d = Decoder::new(Channel::Bulk);
        let big = vec![0u8; MAX_CONTROL_PAYLOAD + 1];
        assert_eq!(d.push(&encode(Kind::Bulk, &big)).unwrap().len(), 1);

        let mut c = Decoder::new(Channel::Control);
        assert_eq!(
            c.push(&encode(Kind::Bulk, b"x")),
            Err(FrameError::KindNotAllowed { kind: Kind::Bulk, channel: Channel::Control })
        );
        let mut u = Decoder::new(Channel::Bulk);
        assert_eq!(u.push(&[0, 0, 0, 0, 9]), Err(FrameError::UnknownKind(9)));
    }
}
