//! Windows system actions for the router (docs/06 "System", WP4.4):
//! the console session's state, the clock, and shutdown / restart / sign-out.

use std::ptr::{null, null_mut};
use std::sync::mpsc::Sender;
use std::thread;
use std::time::Duration;

use proto::v1::{shutdown, SessionState};
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, FILETIME, HANDLE, LUID, SYSTEMTIME};
use windows_sys::Win32::Security::{
    AdjustTokenPrivileges, LookupPrivilegeValueW, LUID_AND_ATTRIBUTES, SE_PRIVILEGE_ENABLED, TOKEN_ADJUST_PRIVILEGES,
    TOKEN_PRIVILEGES, TOKEN_QUERY,
};
use windows_sys::Win32::System::RemoteDesktop::{
    WTSFreeMemory, WTSGetActiveConsoleSessionId, WTSLogoffSession, WTSQuerySessionInformationW, WTSSessionInfoEx,
    WTS_CURRENT_SERVER_HANDLE, WTSINFOEXW, WTS_SESSIONSTATE_LOCK,
};
use windows_sys::Win32::System::Shutdown::{
    InitiateSystemShutdownExW, SHTDN_REASON_FLAG_PLANNED, SHTDN_REASON_MAJOR_OTHER, SHTDN_REASON_MINOR_OTHER,
};
use windows_sys::Win32::System::SystemInformation::SetSystemTime;
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows_sys::Win32::System::Time::FileTimeToSystemTime;

use crate::serve::Event;
use transport::win::wide;

/// How often the console session is polled.
const POLL: Duration = Duration::from_secs(2);

/// The console session now. `logged_on` means a user name is attached to
/// it (OOBE's temporary `defaultuser0` counts; the host tells it apart).
/// `secure_desktop` is not detected yet and stays false.
pub fn console_session_state() -> SessionState {
    let id = unsafe { WTSGetActiveConsoleSessionId() };
    if id == u32::MAX {
        return SessionState::default();
    }
    let mut buf: *mut u16 = null_mut();
    let mut bytes = 0u32;
    let ok = unsafe { WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, id, WTSSessionInfoEx, &mut buf, &mut bytes) } != 0;
    if !ok || buf.is_null() || (bytes as usize) < size_of::<WTSINFOEXW>() {
        if !buf.is_null() {
            unsafe { WTSFreeMemory(buf.cast()) };
        }
        return SessionState::default();
    }
    let info = unsafe { &*(buf as *const WTSINFOEXW) };
    let state = if info.Level == 1 {
        let l1 = unsafe { info.Data.WTSInfoExLevel1 };
        let end = l1.UserName.iter().position(|&c| c == 0).unwrap_or(l1.UserName.len());
        let user: String = String::from_utf16_lossy(&l1.UserName[..end]).chars().filter(|c| !c.is_control()).take(64).collect();
        SessionState {
            logged_on: !user.is_empty(),
            // Windows 10+: LOCK = 0, UNLOCK = 1, unknown = -1.
            locked: !user.is_empty() && l1.SessionFlags as u32 == WTS_SESSIONSTATE_LOCK,
            user,
            secure_desktop: false,
        }
    } else {
        SessionState::default()
    };
    unsafe { WTSFreeMemory(buf.cast()) };
    state
}

/// Posts the console session's state every [`POLL`] (the router drops repeats).
pub fn spawn_poller(tx: Sender<Event>) -> std::io::Result<()> {
    thread::Builder::new().name("session-state".into()).spawn(move || loop {
        if tx.send(Event::SessionState(console_session_state())).is_err() {
            return;
        }
        thread::sleep(POLL);
    })?;
    Ok(())
}

/// Turns on one of this process's privileges (LocalSystem holds them
/// disabled), e.g. "SeShutdownPrivilege".
fn enable_privilege(name: &str) -> Result<(), String> {
    let mut token: HANDLE = null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &mut token) } == 0 {
        return Err(format!("OpenProcessToken failed ({})", unsafe { GetLastError() }));
    }
    let w = wide(name);
    let mut luid = LUID { LowPart: 0, HighPart: 0 };
    let result = if unsafe { LookupPrivilegeValueW(null(), w.as_ptr(), &mut luid) } == 0 {
        Err(format!("LookupPrivilegeValue({name}) failed ({})", unsafe { GetLastError() }))
    } else {
        let tp = TOKEN_PRIVILEGES { PrivilegeCount: 1, Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }] };
        let ok = unsafe { AdjustTokenPrivileges(token, 0, &tp, 0, null_mut(), null_mut()) } != 0;
        // Succeeds with ERROR_NOT_ALL_ASSIGNED (1300) when we lack it.
        let err = unsafe { GetLastError() };
        if !ok || err == 1300 { Err(format!("cannot enable {name} ({err})")) } else { Ok(()) }
    };
    unsafe { CloseHandle(token) };
    result
}

/// Sets the system clock (UTC) to `unix_nanos`.
pub fn set_time(unix_nanos: i64) -> Result<(), String> {
    enable_privilege("SeSystemtimePrivilege")?;
    // FILETIME: 100 ns intervals since 1601-01-01.
    let ticks = (unix_nanos / 100) as u64 + 116_444_736_000_000_000;
    let ft = FILETIME { dwLowDateTime: ticks as u32, dwHighDateTime: (ticks >> 32) as u32 };
    let mut st: SYSTEMTIME = unsafe { std::mem::zeroed() };
    if unsafe { FileTimeToSystemTime(&ft, &mut st) } == 0 {
        return Err(format!("FileTimeToSystemTime failed ({})", unsafe { GetLastError() }));
    }
    if unsafe { SetSystemTime(&st) } == 0 {
        return Err(format!("SetSystemTime failed ({})", unsafe { GetLastError() }));
    }
    Ok(())
}

/// Starts `mode` one second from now, after the `Ack` has left. Apps are
/// asked to close, not forced: one that refuses keeps Windows up, and the
/// host falls back to ACPI and then a forced stop.
pub fn shutdown(mode: shutdown::Mode) -> Result<(), String> {
    match mode {
        shutdown::Mode::Shutdown | shutdown::Mode::Restart => enable_privilege("SeShutdownPrivilege")?,
        shutdown::Mode::Logoff => {}
        _ => return Err(format!("{} is not supported", mode.as_str_name())),
    }
    thread::Builder::new()
        .name("shutdown".into())
        .spawn(move || {
            thread::sleep(Duration::from_secs(1));
            let ok = match mode {
                shutdown::Mode::Logoff => {
                    let id = unsafe { WTSGetActiveConsoleSessionId() };
                    unsafe { WTSLogoffSession(WTS_CURRENT_SERVER_HANDLE, id, 0) != 0 }
                }
                _ => {
                    let msg = wide("Seemless: shutting down at the Mac's request");
                    let reason = SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_MINOR_OTHER | SHTDN_REASON_FLAG_PLANNED;
                    let reboot = i32::from(mode == shutdown::Mode::Restart);
                    unsafe { InitiateSystemShutdownExW(null(), msg.as_ptr(), 0, 0, reboot, reason) != 0 }
                }
            };
            if !ok {
                crate::log(&format!("{} failed ({})", mode.as_str_name(), unsafe { GetLastError() }));
            }
        })
        .map_err(|e| e.to_string())?;
    Ok(())
}
