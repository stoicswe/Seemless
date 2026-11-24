//! Byte links between the agent processes and the host (docs/06 "Transport
//! and framing").
//!
//! - [`link`]: framed `Envelope` reader and writer threads over any byte
//!   stream. Platform-independent; tested on the Mac with unix sockets.
//! - `win` (Windows only): the virtio-serial port (`\\.\Global\<name>`,
//!   overlapped I/O) and the service ↔ session named pipe.

pub mod link;
pub mod log;

#[cfg(windows)]
pub mod win;
