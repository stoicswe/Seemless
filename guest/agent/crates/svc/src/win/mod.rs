//! Windows side of the service: SCM entry point and wiring.
//!
//! `seemless-agent-svc.exe`            run as the `SeemlessAgent` service (SCM)
//! `seemless-agent-svc.exe console`    the same loop in a console (debugging)
//! `seemless-agent-svc.exe info`       print GuestInfo and exit
//!
//! Install and remove with `guest/tools/agent/install.cmd` / `uninstall.cmd`
//! (`sc.exe`; auto-start, restart on failure).

pub mod info;
pub mod supervisor;

use std::path::PathBuf;
use std::ptr::null_mut;
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use windows_sys::Win32::Foundation::{GetLastError, NO_ERROR};
use windows_sys::Win32::System::Services::{
    RegisterServiceCtrlHandlerExW, SetServiceStatus, StartServiceCtrlDispatcherW, SERVICE_ACCEPT_SHUTDOWN, SERVICE_ACCEPT_STOP,
    SERVICE_CONTROL_INTERROGATE, SERVICE_CONTROL_SHUTDOWN, SERVICE_CONTROL_STOP, SERVICE_RUNNING, SERVICE_START_PENDING,
    SERVICE_STATUS, SERVICE_STATUS_HANDLE, SERVICE_STOPPED, SERVICE_STOP_PENDING, SERVICE_TABLE_ENTRYW, SERVICE_WIN32_OWN_PROCESS,
};

use crate::router::Router;
use crate::serve::{self, Event};

pub const SERVICE_NAME: &str = "SeemlessAgent";
/// virtio-serial port names (docs/02; `QEMUCommand.agentPortName`).
pub const CONTROL_PORT: &str = "app.seemless.agent.0";
pub const SESSION_EXE: &str = "seemless-agent.exe";

static STOP: OnceLock<Mutex<Sender<Event>>> = OnceLock::new();
static STATUS: OnceLock<usize> = OnceLock::new();

fn exe_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(PathBuf::from)).unwrap_or_default()
}

fn log_path() -> PathBuf {
    let base = std::env::var_os("ProgramData").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
    base.join(r"Seemless\logs\agent-svc.log")
}

/// Keeps one previous log (`.1`) once the current one passes 1 MiB.
fn open_log() {
    let path = log_path();
    if std::fs::metadata(&path).map(|m| m.len() > 1 << 20).unwrap_or(false) {
        let _ = std::fs::rename(&path, path.with_extension("log.1"));
    }
    let _ = crate::log_to_file(&path);
}

/// Runs the service loop until a stop arrives on the returned channel.
fn serve_until_stopped(supervise: bool) {
    let build = crate::build_string("seemless-agent-svc");
    let (tx, rx) = serve::channel();
    let _ = STOP.set(Mutex::new(tx.clone()));
    crate::log(&format!("{build} starting; control port {CONTROL_PORT}"));

    let version = build.clone();
    let router = Router::new(build, move || info::guest_info(&version));
    if let Err(e) = serve::spawn_host_link(tx.clone(), || transport::win::open_serial(CONTROL_PORT), Duration::from_secs(1)) {
        crate::log(&format!("host link thread: {e}"));
        return;
    }

    let supervisor = match transport::win::PipeServer::new() {
        Ok(mut pipe) => {
            let sup = if supervise {
                match supervisor::Supervisor::spawn(exe_dir().join(SESSION_EXE), pipe.path.clone()) {
                    Ok(s) => Some(s),
                    Err(e) => {
                        crate::log(&format!("supervisor thread: {e}"));
                        None
                    }
                }
            } else {
                crate::log(&format!("console mode: start the session agent yourself with --pipe {}", pipe.path));
                None
            };
            let expected = sup.as_ref().map(|s| s.pid.clone());
            let accepted = serve::spawn_session_acceptor(tx.clone(), move || {
                let expected = expected.clone();
                pipe.accept(&move |pid| match &expected {
                    Some(p) => p.load(std::sync::atomic::Ordering::SeqCst) == pid,
                    None => true, // console mode
                })
            });
            if let Err(e) = accepted {
                crate::log(&format!("session acceptor thread: {e}"));
            }
            sup
        }
        Err(e) => {
            crate::log(&format!("session pipe not created: {e}; running without a session agent"));
            None
        }
    };

    serve::run(router, rx);
    if let Some(s) = supervisor {
        s.stop();
        std::thread::sleep(Duration::from_millis(300));
    }
    crate::log("stopped");
}

fn set_status(state: u32, wait_hint_ms: u32) {
    let Some(&h) = STATUS.get() else { return };
    let status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: if state == SERVICE_RUNNING { SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN } else { 0 },
        dwWin32ExitCode: NO_ERROR,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: 0,
        dwWaitHint: wait_hint_ms,
    };
    unsafe { SetServiceStatus(h as SERVICE_STATUS_HANDLE, &status) };
}

unsafe extern "system" fn control_handler(control: u32, _: u32, _: *mut core::ffi::c_void, _: *mut core::ffi::c_void) -> u32 {
    match control {
        SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN => {
            set_status(SERVICE_STOP_PENDING, 3000);
            if let Some(Ok(t)) = STOP.get().map(|tx| tx.lock()) {
                let _ = t.send(Event::Stop);
            }
            NO_ERROR
        }
        SERVICE_CONTROL_INTERROGATE => NO_ERROR,
        _ => 120, // ERROR_CALL_NOT_IMPLEMENTED
    }
}

unsafe extern "system" fn service_main(_argc: u32, _argv: *mut *mut u16) {
    let name = transport::win::wide(SERVICE_NAME);
    let h = unsafe { RegisterServiceCtrlHandlerExW(name.as_ptr(), Some(control_handler), null_mut()) };
    if h.is_null() {
        crate::log(&format!("RegisterServiceCtrlHandlerEx failed ({})", unsafe { GetLastError() }));
        return;
    }
    let _ = STATUS.set(h as usize);
    set_status(SERVICE_START_PENDING, 3000);
    open_log();
    set_status(SERVICE_RUNNING, 0);
    serve_until_stopped(true);
    set_status(SERVICE_STOPPED, 0);
}

pub fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => {
            let mut name = transport::win::wide(SERVICE_NAME);
            let table = [
                SERVICE_TABLE_ENTRYW { lpServiceName: name.as_mut_ptr(), lpServiceProc: Some(service_main) },
                SERVICE_TABLE_ENTRYW { lpServiceName: null_mut(), lpServiceProc: None },
            ];
            if unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } == 0 {
                let err = unsafe { GetLastError() };
                eprintln!("seemless-agent-svc: not started by the service manager (error {err}).");
                eprintln!("Usage: seemless-agent-svc [console [--supervise] | info]  (install with install.cmd)");
                std::process::exit(2);
            }
        }
        Some("console") => serve_until_stopped(args.iter().any(|a| a == "--supervise")),
        Some("info") => {
            let i = info::guest_info(&crate::build_string("seemless-agent-svc"));
            println!("windows: {}\nagent:   {}\ngpu:     {}", i.os_build, i.agent_version, i.gpu_adapter);
            for d in i.driver_versions {
                println!("driver:  {} {}", d.name, d.version);
            }
        }
        Some(other) => {
            eprintln!("unknown command {other:?}. Usage: seemless-agent-svc [console [--supervise] | info]");
            std::process::exit(2);
        }
    }
}
