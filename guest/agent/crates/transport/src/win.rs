//! Windows transports (docs/06 "Transport and framing").
//!
//! - [`open_serial`]: a virtio-serial port by name. The vioserial driver
//!   publishes each named port as `\\.\Global\<name>` (the same path
//!   qemu-guest-agent opens), so no SetupAPI enumeration is needed.
//! - [`PipeServer`] / [`pipe_connect`]: the service ↔ session agent pipe.
//!
//! Every handle is opened for overlapped I/O, so one thread can block in
//! `ReadFile` while another writes: a synchronous handle would serialise
//! the two and a pending read would stall every write.

use std::ffi::OsStr;
use std::io::{self, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_OPERATION_ABORTED, ERROR_PIPE_CONNECTED,
    GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows_sys::Win32::Security::Cryptography::{BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG};
use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, OPEN_EXISTING, PIPE_ACCESS_DUPLEX,
    SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT,
};
use windows_sys::Win32::System::IO::{CancelIoEx, DeviceIoControl, GetOverlappedResult, GetOverlappedResultEx, OVERLAPPED};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS,
    PIPE_TYPE_BYTE, PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::CreateEventW;

use crate::link::Duplex;

/// NUL-terminated UTF-16 for Win32 calls.
pub fn wide(s: impl AsRef<OsStr>) -> Vec<u16> {
    s.as_ref().encode_wide().chain(Some(0)).collect()
}

/// `n` random bytes from the system RNG, as lowercase hex.
pub fn random_hex(n: usize) -> io::Result<String> {
    let mut buf = vec![0u8; n];
    let status = unsafe { BCryptGenRandom(null_mut(), buf.as_mut_ptr(), n as u32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if status != 0 {
        return Err(io::Error::other(format!("BCryptGenRandom failed: {status:#x}")));
    }
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

/// An owned handle opened with `FILE_FLAG_OVERLAPPED`. Shared by the reader
/// and writer of one connection; closed when the last one drops.
struct Handle {
    raw: HANDLE,
    closed: AtomicBool,
}

// The handle is a kernel object reference; Win32 allows its use from any thread.
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}

impl Handle {
    fn close(&self) {
        if !self.closed.swap(true, Ordering::SeqCst) {
            unsafe { CancelIoEx(self.raw, null()) };
        }
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.raw) };
    }
}

/// An event for one direction's OVERLAPPED.
struct Event(HANDLE);
unsafe impl Send for Event {}
impl Event {
    fn new() -> io::Result<Self> {
        let h = unsafe { CreateEventW(null(), 1, 0, null()) };
        if h.is_null() { Err(io::Error::last_os_error()) } else { Ok(Self(h)) }
    }
}
impl Drop for Event {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

/// Runs one overlapped operation to completion.
fn overlapped(handle: &Handle, event: &Event, op: impl FnOnce(*mut OVERLAPPED) -> i32) -> io::Result<usize> {
    overlapped_within(handle, event, None, op)
}

/// Like [`overlapped`], but gives up after `timeout_ms`: the operation is
/// cancelled and `ErrorKind::TimedOut` returned.
fn overlapped_within(handle: &Handle, event: &Event, timeout_ms: Option<u32>, op: impl FnOnce(*mut OVERLAPPED) -> i32) -> io::Result<usize> {
    if handle.closed.load(Ordering::SeqCst) {
        return Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed"));
    }
    let mut ov: OVERLAPPED = unsafe { std::mem::zeroed() };
    ov.hEvent = event.0;
    if op(&mut ov) == 0 {
        let err = unsafe { GetLastError() };
        if err != ERROR_IO_PENDING {
            return Err(io_error(err));
        }
    }
    let mut n = 0u32;
    if let Some(ms) = timeout_ms {
        if unsafe { GetOverlappedResultEx(handle.raw, &ov, &mut n, ms, 0) } != 0 {
            return Ok(n as usize);
        }
        let err = unsafe { GetLastError() };
        if err != WAIT_TIMEOUT {
            return Err(io_error(err));
        }
        // Cancel, then wait for the cancellation so `ov` can go.
        unsafe { CancelIoEx(handle.raw, &ov) };
        unsafe { GetOverlappedResult(handle.raw, &ov, &mut n, 1) };
        return Err(io::Error::new(io::ErrorKind::TimedOut, format!("no progress in {ms} ms")));
    }
    if unsafe { GetOverlappedResult(handle.raw, &ov, &mut n, 1) } == 0 {
        return Err(io_error(unsafe { GetLastError() }));
    }
    Ok(n as usize)
}

fn io_error(code: u32) -> io::Error {
    match code {
        ERROR_BROKEN_PIPE => io::Error::new(io::ErrorKind::BrokenPipe, "broken pipe"),
        ERROR_OPERATION_ABORTED => io::Error::new(io::ErrorKind::ConnectionAborted, "closed"),
        c => io::Error::from_raw_os_error(c as i32),
    }
}

struct HandleReader(Arc<Handle>, Event);
struct HandleWriter(Arc<Handle>, Event);

/// vioserial's `IOCTL_GET_INFORMATION` (kvm-guest-drivers-windows
/// `vioserial/sys/public.h`: `CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800,
/// METHOD_OUT_DIRECT, FILE_ANY_ACCESS)`), answering `VIRTIO_PORT_INFO
/// { UINT Id; BOOLEAN OutVqFull; BOOLEAN HostConnected; BOOLEAN
/// GuestConnected; CHAR Name[]; }`.
const IOCTL_VIOSERIAL_GET_INFORMATION: u32 = 0x0022_2002;
/// How long one write to the host may take before it is abandoned.
const SERIAL_WRITE_TIMEOUT_MS: u32 = 5_000;

/// Writes to a virtio-serial port. A write while the host side is closed
/// can stay queued forever (seen on WP4.4's VM: the session agent's first
/// SessionState after the host left blocked every later write, including
/// the Hello reply to the next host). So: frames are dropped while the
/// driver says the host is not connected, and a write that makes no
/// progress for 5 s is cancelled and dropped. The writer never fails on
/// these; the next host starts over with Hello.
struct SerialWriter {
    w: HandleWriter,
    info_event: Event,
    dropped: u64,
}

impl SerialWriter {
    /// `Some(connected)` from the driver; None if it does not answer the IOCTL.
    fn host_connected(&self) -> Option<bool> {
        let h = &self.w.0;
        let mut buf = [0u8; 256];
        let raw = h.raw;
        let out = buf.as_mut_ptr();
        let n = overlapped_within(h, &self.info_event, Some(1_000), |ov| unsafe {
            DeviceIoControl(raw, IOCTL_VIOSERIAL_GET_INFORMATION, null(), 0, out.cast(), buf.len() as u32, null_mut(), ov)
        })
        .ok()?;
        (n >= 6).then(|| buf[5] != 0)
    }

    fn drop_frame(&mut self, why: &str, len: usize) -> io::Result<usize> {
        self.dropped += 1;
        if self.dropped.is_power_of_two() {
            crate::log::log(&format!("host port: {} frame(s) dropped ({why})", self.dropped));
        }
        Ok(len)
    }
}

impl Write for SerialWriter {
    /// Called with whole frames (`Writer` uses `write_all`); a dropped
    /// frame reports as written so `write_all` moves on.
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.host_connected() == Some(false) {
            return self.drop_frame("host not connected", buf.len());
        }
        let len = buf.len().min(u32::MAX as usize) as u32;
        let raw = self.w.0.raw;
        let ptr = buf.as_ptr();
        match overlapped_within(&self.w.0, &self.w.1, Some(SERIAL_WRITE_TIMEOUT_MS), |ov| unsafe {
            WriteFile(raw, ptr, len, null_mut(), ov)
        }) {
            Err(e) if e.kind() == io::ErrorKind::TimedOut => self.drop_frame("write timed out", buf.len()),
            // STATUS_CANT_WAIT: the driver refuses writes while the host is away.
            Err(e) if e.raw_os_error() == Some(554) => self.drop_frame("host not connected", buf.len()),
            r => r,
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Read for HandleReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let len = buf.len().min(u32::MAX as usize) as u32;
        let raw = self.0.raw;
        let ptr = buf.as_mut_ptr();
        match overlapped(&self.0, &self.1, |ov| unsafe { ReadFile(raw, ptr, len, null_mut(), ov) }) {
            Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(0),
            r => r,
        }
    }
}

impl Write for HandleWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let len = buf.len().min(u32::MAX as usize) as u32;
        let raw = self.0.raw;
        let ptr = buf.as_ptr();
        overlapped(&self.0, &self.1, |ov| unsafe { WriteFile(raw, ptr, len, null_mut(), ov) })
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn duplex(raw: HANDLE) -> io::Result<Duplex> {
    let h = Arc::new(Handle { raw, closed: AtomicBool::new(false) });
    let closer = h.clone();
    Ok(Duplex {
        reader: Box::new(HandleReader(h.clone(), Event::new()?)),
        writer: Box::new(HandleWriter(h, Event::new()?)),
        close: Box::new(move || closer.close()),
    })
}

fn serial_duplex(raw: HANDLE) -> io::Result<Duplex> {
    let h = Arc::new(Handle { raw, closed: AtomicBool::new(false) });
    let closer = h.clone();
    Ok(Duplex {
        reader: Box::new(HandleReader(h.clone(), Event::new()?)),
        writer: Box::new(SerialWriter { w: HandleWriter(h, Event::new()?), info_event: Event::new()?, dropped: 0 }),
        close: Box::new(move || closer.close()),
    })
}

fn open_existing(path: &str, extra_flags: u32) -> io::Result<HANDLE> {
    let p = wide(path);
    let h = unsafe {
        CreateFileW(p.as_ptr(), GENERIC_READ | GENERIC_WRITE, 0, null(), OPEN_EXISTING, FILE_FLAG_OVERLAPPED | extra_flags, null_mut())
    };
    if h == INVALID_HANDLE_VALUE { Err(io::Error::last_os_error()) } else { Ok(h) }
}

/// Opens the virtio-serial port QEMU named `name` (docs/02:
/// `app.seemless.agent.0`, `app.seemless.bulk.0`). Fails with "not found"
/// while the vioserial driver is missing or the device is absent.
pub fn open_serial(name: &str) -> io::Result<Duplex> {
    serial_duplex(open_existing(&format!(r"\\.\Global\{name}"), 0)?)
}

/// Opens the session pipe as a client. Identification-level impersonation
/// only: the service may check who we are, not act as us.
pub fn pipe_connect(path: &str) -> io::Result<Duplex> {
    duplex(open_existing(path, SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION)?)
}

/// The service's end of the session pipe.
///
/// The name carries 128 random bits chosen per service start and is passed
/// to the session agent on its command line, and the first instance is
/// created with `FILE_FLAG_FIRST_PIPE_INSTANCE`: no other process can
/// create the pipe first and pose as the service. The DACL admits SYSTEM
/// and interactive users; [`PipeServer::accept`] additionally checks the
/// client's process id.
pub struct PipeServer {
    pub path: String,
    first: bool,
    sd: PSECURITY_DESCRIPTOR,
}

unsafe impl Send for PipeServer {}

/// SYSTEM: full; interactive users: read/write. Protected (no inheritance).
const PIPE_SDDL: &str = "D:P(A;;GA;;;SY)(A;;GRGW;;;IU)";

impl PipeServer {
    pub fn new() -> io::Result<Self> {
        let path = format!(r"\\.\pipe\seemless-agent-{}", random_hex(16)?);
        let sddl = wide(PIPE_SDDL);
        let mut sd: PSECURITY_DESCRIPTOR = null_mut();
        if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut sd, null_mut()) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { path, first: true, sd })
    }

    /// Waits for the next client. `allowed(pid)` decides whether the
    /// connected process may stay; rejected clients are disconnected and
    /// the wait goes on.
    pub fn accept(&mut self, allowed: &dyn Fn(u32) -> bool) -> io::Result<Duplex> {
        loop {
            let sa = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: self.sd,
                bInheritHandle: 0,
            };
            let mut flags = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
            if self.first {
                flags |= FILE_FLAG_FIRST_PIPE_INSTANCE;
            }
            let name = wide(&self.path);
            let raw = unsafe {
                CreateNamedPipeW(
                    name.as_ptr(),
                    flags,
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                    4,
                    64 * 1024,
                    64 * 1024,
                    0,
                    &sa,
                )
            };
            if raw == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error());
            }
            self.first = false;
            let h = Handle { raw, closed: AtomicBool::new(false) };
            let event = Event::new()?;
            let connected = overlapped(&h, &event, |ov| unsafe { ConnectNamedPipe(raw, ov) });
            match connected {
                Ok(_) => {}
                Err(e) if e.raw_os_error() == Some(ERROR_PIPE_CONNECTED as i32) => {}
                Err(e) => return Err(e),
            }
            let mut pid = 0u32;
            let ok = unsafe { GetNamedPipeClientProcessId(raw, &mut pid) } != 0;
            if !ok || !allowed(pid) {
                crate_log_reject(pid);
                drop(h); // closes and disconnects the client
                continue;
            }
            // Hand the raw handle over without closing it.
            let raw = h.raw;
            std::mem::forget(h);
            return duplex(raw);
        }
    }
}

fn crate_log_reject(pid: u32) {
    eprintln!("session pipe: rejected client process {pid}");
}

impl Drop for PipeServer {
    fn drop(&mut self) {
        unsafe { LocalFree(self.sd as _) };
    }
}
