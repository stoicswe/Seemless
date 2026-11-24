//! Starts the session agent in the interactive session and keeps it running
//! (docs/06 "Agent processes").
//!
//! Every 2 s: if no session agent runs and a user is logged on at the
//! console (`WTSGetActiveConsoleSessionId` + `WTSQueryUserToken`), start
//! `seemless-agent.exe --pipe <path>` as that user on `winsta0\default`.
//! An agent that exits is restarted with a backoff of 1 s doubling to 30 s,
//! reset once it has run for a minute. Logoff ends the agent with the
//! session; the next logon starts a new one.
//!
//! The pid of the running agent is published so the pipe accepts only it.

use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicU32, AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows_sys::Win32::System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock};
use windows_sys::Win32::System::RemoteDesktop::{WTSGetActiveConsoleSessionId, WTSQueryUserToken};
use windows_sys::Win32::System::Threading::{
    CreateProcessAsUserW, GetExitCodeProcess, TerminateProcess, WaitForSingleObject, CREATE_NO_WINDOW, CREATE_UNICODE_ENVIRONMENT,
    PROCESS_INFORMATION, STARTUPINFOW,
};

use transport::win::wide;

pub struct Supervisor {
    pub pid: Arc<AtomicU32>,
    stop: Arc<AtomicBool>,
}

impl Supervisor {
    pub fn spawn(exe: PathBuf, pipe: String) -> std::io::Result<Self> {
        let pid = Arc::new(AtomicU32::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (p, s) = (pid.clone(), stop.clone());
        thread::Builder::new().name("supervisor".into()).spawn(move || supervise(exe, pipe, p, s))?;
        Ok(Self { pid, stop })
    }

    /// Ends the session agent (service stop).
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

struct Child {
    process: HANDLE,
    started: Instant,
}

fn supervise(exe: PathBuf, pipe: String, pid: Arc<AtomicU32>, stop: Arc<AtomicBool>) {
    let mut backoff = Duration::from_secs(1);
    let mut child: Option<Child> = None;
    let mut last_error = String::new();
    loop {
        if stop.load(Ordering::SeqCst) {
            if let Some(c) = child.take() {
                unsafe {
                    TerminateProcess(c.process, 0);
                    CloseHandle(c.process);
                }
            }
            pid.store(0, Ordering::SeqCst);
            return;
        }
        if let Some(c) = &child {
            match unsafe { WaitForSingleObject(c.process, 500) } {
                WAIT_TIMEOUT => continue,
                WAIT_OBJECT_0 => {
                    let mut code = 0u32;
                    unsafe { GetExitCodeProcess(c.process, &mut code) };
                    let ran = c.started.elapsed();
                    crate::log(&format!("session agent exited with {code:#x} after {}s", ran.as_secs()));
                    unsafe { CloseHandle(c.process) };
                    child = None;
                    pid.store(0, Ordering::SeqCst);
                    backoff = if ran > Duration::from_secs(60) { Duration::from_secs(1) } else { (backoff * 2).min(Duration::from_secs(30)) };
                    sleep_unless_stopped(backoff, &stop);
                    continue;
                }
                _ => {
                    thread::sleep(Duration::from_millis(500));
                    continue;
                }
            }
        }
        match start(&exe, &pipe) {
            Ok((process, id)) => {
                crate::log(&format!("session agent started (pid {id})"));
                last_error.clear();
                pid.store(id, Ordering::SeqCst);
                child = Some(Child { process, started: Instant::now() });
            }
            Err(e) => {
                if e != last_error {
                    crate::log(&format!("session agent not started: {e}"));
                    last_error = e;
                }
                sleep_unless_stopped(Duration::from_secs(2), &stop);
            }
        }
    }
}

fn sleep_unless_stopped(d: Duration, stop: &AtomicBool) {
    let end = Instant::now() + d;
    while Instant::now() < end && !stop.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(100));
    }
}

/// Starts the agent in the console session as its user.
fn start(exe: &Path, pipe: &str) -> Result<(HANDLE, u32), String> {
    let session = unsafe { WTSGetActiveConsoleSessionId() };
    if session == u32::MAX {
        return Err("no console session".into());
    }
    let mut token: HANDLE = null_mut();
    if unsafe { WTSQueryUserToken(session, &mut token) } == 0 {
        // ERROR_NO_TOKEN (1008): nobody is logged on yet.
        return Err(format!("no user logged on in session {session} (error {})", unsafe { GetLastError() }));
    }
    let mut env: *mut core::ffi::c_void = null_mut();
    let have_env = unsafe { CreateEnvironmentBlock(&mut env, token, 0) } != 0;
    let mut cmd = wide(format!("\"{}\" --pipe {pipe}", exe.display()));
    let app = wide(exe.as_os_str());
    let mut desktop = wide(r"winsta0\default");
    let mut si: STARTUPINFOW = unsafe { std::mem::zeroed() };
    si.cb = size_of::<STARTUPINFOW>() as u32;
    si.lpDesktop = desktop.as_mut_ptr();
    let mut pi: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    let ok = unsafe {
        CreateProcessAsUserW(
            token,
            app.as_ptr(),
            cmd.as_mut_ptr(),
            null(),
            null(),
            0,
            CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW,
            if have_env { env } else { null() },
            null(),
            &si,
            &mut pi,
        )
    } != 0;
    let err = unsafe { GetLastError() };
    unsafe {
        if have_env {
            DestroyEnvironmentBlock(env);
        }
        CloseHandle(token);
    }
    if !ok {
        return Err(format!("CreateProcessAsUser failed (error {err})"));
    }
    unsafe { CloseHandle(pi.hThread) };
    Ok((pi.hProcess, pi.dwProcessId))
}
