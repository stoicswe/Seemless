//! Framed envelope links over a byte stream.
//!
//! [`spawn_reader`] decodes frames on its own thread and posts each
//! `Envelope` to a channel. On a framing or decoding error it posts
//! [`Received::Reset`] and starts over with a fresh decoder (docs/06: the
//! receiver resets the channel; frames before the bad one are delivered).
//! [`Writer`] owns a writer thread with a bounded queue, so a port the host
//! is not reading never blocks the caller: when the queue is full, frames are
//! dropped and counted, which matches virtio-serial dropping bytes while the
//! host has the port closed.

use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender, SyncSender, TrySendError};
use std::sync::Arc;
use std::thread;

use proto::frame::{Channel, Decoder, Kind};
use proto::v1::Envelope;
use proto::Message;

/// One open byte stream, split for the reader and writer threads.
pub struct Duplex {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    /// Ends the connection (cancels pending I/O); the reader then fails.
    pub close: Box<dyn Fn() + Send>,
}

/// Frames queued per writer before new ones are dropped.
pub const WRITE_QUEUE: usize = 256;

#[derive(Debug)]
pub enum Received {
    Envelope(Envelope),
    /// The peer sent something invalid; the decoder was reset.
    Reset(String),
    /// End of stream or a read error. The reader thread has exited.
    Closed(String),
}

/// Reads `reader` until it ends, posting `wrap(event)` to `tx`. Stops early
/// if the receiver is gone.
pub fn spawn_reader<R, T, F>(name: &str, mut reader: R, channel: Channel, tx: Sender<T>, wrap: F) -> io::Result<thread::JoinHandle<()>>
where
    R: Read + Send + 'static,
    T: Send + 'static,
    F: Fn(Received) -> T + Send + 'static,
{
    thread::Builder::new().name(format!("{name}-read")).spawn(move || {
        let mut decoder = Decoder::new(channel);
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) => {
                    let _ = tx.send(wrap(Received::Closed("end of stream".into())));
                    return;
                }
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => {
                    let _ = tx.send(wrap(Received::Closed(e.to_string())));
                    return;
                }
            };
            let (frames, error) = decoder.decode(&buf[..n]);
            for frame in frames {
                let event = match frame.kind {
                    Kind::Envelope => match Envelope::decode(frame.payload.as_slice()) {
                        Ok(env) => Received::Envelope(env),
                        Err(e) => {
                            decoder = Decoder::new(channel);
                            if tx.send(wrap(Received::Reset(format!("undecodable Envelope: {e}")))).is_err() {
                                return;
                            }
                            break;
                        }
                    },
                    // Bulk chunks have no consumer yet (first bulk user: icons).
                    Kind::Bulk => continue,
                };
                if tx.send(wrap(event)).is_err() {
                    return;
                }
            }
            if let Some(e) = error {
                decoder = Decoder::new(channel);
                if tx.send(wrap(Received::Reset(e.to_string()))).is_err() {
                    return;
                }
            }
        }
    })
}

/// Queue in front of a writer thread. Cloning shares the queue.
#[derive(Clone)]
pub struct Writer {
    tx: SyncSender<Vec<u8>>,
    dropped: Arc<AtomicU64>,
}

impl Writer {
    /// `on_error` runs once on the writer thread if a write fails; the
    /// thread then exits and later sends are dropped.
    pub fn spawn<W, E>(name: &str, mut writer: W, on_error: E) -> io::Result<Self>
    where
        W: Write + Send + 'static,
        E: FnOnce(io::Error) + Send + 'static,
    {
        let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(WRITE_QUEUE);
        thread::Builder::new().name(format!("{name}-write")).spawn(move || {
            for frame in rx {
                if let Err(e) = writer.write_all(&frame).and_then(|_| writer.flush()) {
                    on_error(e);
                    return;
                }
            }
        })?;
        Ok(Self { tx, dropped: Arc::new(AtomicU64::new(0)) })
    }

    /// Queues `env` as one control frame. Returns false if it was dropped.
    pub fn send(&self, env: &Envelope) -> bool {
        match self.tx.try_send(env.to_frame()) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                false
            }
        }
    }

    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use proto::v1::envelope::Body;
    use proto::v1::Ping;
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    fn ping(seq: u64) -> Envelope {
        Envelope::new(seq, Body::Ping(Ping { nonce: seq }))
    }

    #[test]
    fn round_trip_and_reset_on_garbage() {
        let (a, mut b) = UnixStream::pair().unwrap();
        let (tx, rx) = mpsc::channel();
        spawn_reader("t", a, Channel::Control, tx, |r| r).unwrap();
        let mut wire = ping(1).to_frame();
        wire.extend([0, 0, 0, 0, 9]); // unknown kind
        b.write_all(&wire).unwrap();
        let t = Duration::from_secs(5);
        assert!(matches!(rx.recv_timeout(t).unwrap(), Received::Envelope(e) if e.seq == 1));
        assert!(matches!(rx.recv_timeout(t).unwrap(), Received::Reset(_)));
        // Bytes that arrived in the same read as the bad frame are discarded
        // with it; the next write starts clean.
        b.write_all(&ping(2).to_frame()).unwrap();
        assert!(matches!(rx.recv_timeout(t).unwrap(), Received::Envelope(e) if e.seq == 2));
        // A frame whose payload is not an Envelope.
        b.write_all(&proto::frame::encode(Kind::Envelope, &[0xff, 0xff, 0xff])).unwrap();
        assert!(matches!(rx.recv_timeout(t).unwrap(), Received::Reset(_)));
        drop(b);
        assert!(matches!(rx.recv_timeout(t).unwrap(), Received::Closed(_)));
    }

    #[test]
    fn writer_delivers_frames() {
        let (a, b) = UnixStream::pair().unwrap();
        let w = Writer::spawn("t", a, |_| {}).unwrap();
        assert!(w.send(&ping(7)));
        let (tx, rx) = mpsc::channel();
        spawn_reader("t", b, Channel::Control, tx, |r| r).unwrap();
        assert!(matches!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), Received::Envelope(e) if e.seq == 7));
        assert_eq!(w.dropped(), 0);
    }

    #[test]
    fn full_queue_drops_instead_of_blocking() {
        let (a, _b) = UnixStream::pair().unwrap();
        a.set_nonblocking(false).unwrap();
        let w = Writer::spawn("t", a, |_| {}).unwrap();
        // Nobody reads _b: the socket buffer fills, then the queue.
        let big = Envelope::new(1, Body::Error(proto::v1::Error { code: 0, message: "x".repeat(60_000) }));
        let mut dropped = false;
        for _ in 0..10_000 {
            if !w.send(&big) {
                dropped = true;
                break;
            }
        }
        assert!(dropped);
        assert!(w.dropped() >= 1);
    }
}
