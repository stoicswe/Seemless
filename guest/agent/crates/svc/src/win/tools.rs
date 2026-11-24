//! The Windows [`System`]: `GuestInfo` from the registry, tools updates
//! from an attached volume (docs/06 "Guest tools ISO"); clock and power in
//! `system.rs`.
//!
//! `update_tools(label, version)`:
//! 1. finds the drive whose volume label is `label` (case-insensitive);
//! 2. checks that its `version.txt` reads `version` and `install.cmd` exists;
//! 3. starts `cmd.exe /c <drive>\install.cmd /update`, appending to
//!    `%ProgramData%\Seemless\logs\tools-update.log`, and returns.
//!
//! `install.cmd` waits a moment (so the `Ack` reaches the host), stops this
//! service, swaps the binaries (rename, then copy: works while they run) and
//! starts the service again, which sends the host a new `Hello`. The script
//! is not a child that dies with us: the SCM does not kill a stopped
//! service's children, and it runs in its own process group.

use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use proto::v1::GuestInfo;
use windows_sys::Win32::Storage::FileSystem::{GetLogicalDrives, GetVolumeInformationW};
use windows_sys::Win32::System::Threading::{CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW};

use crate::router::System;
use transport::win::wide;

/// Largest `version.txt` read from the volume.
const MAX_VERSION_FILE: u64 = 256;

pub struct WinSystem {
    pub agent_version: String,
}

impl System for WinSystem {
    fn guest_info(&self) -> GuestInfo {
        super::info::guest_info(&self.agent_version)
    }

    fn set_time(&mut self, unix_nanos: i64) -> Result<(), String> {
        super::system::set_time(unix_nanos)
    }

    fn shutdown(&mut self, mode: proto::v1::shutdown::Mode) -> Result<(), String> {
        super::system::shutdown(mode)
    }

    fn update_tools(&mut self, label: &str, version: &str) -> Result<(), String> {
        let root = find_volume(label).ok_or_else(|| format!("no volume labelled {label} is attached"))?;
        let version_file = root.join("version.txt");
        let len = std::fs::metadata(&version_file).map_err(|e| format!("{}: {e}", version_file.display()))?.len();
        if len > MAX_VERSION_FILE {
            return Err(format!("{} is too large", version_file.display()));
        }
        let found = std::fs::read_to_string(&version_file).map_err(|e| format!("{}: {e}", version_file.display()))?;
        let found = found.trim();
        if found != version {
            return Err(format!("volume {label} holds tools {found:?}, not {version:?}"));
        }
        let script = root.join("install.cmd");
        if !script.is_file() {
            return Err(format!("{} not found", script.display()));
        }
        let log = log_path();
        if let Some(dir) = log.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let windir = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
        // cmd.exe parses its own command line: /s strips the outer quotes and
        // keeps the rest verbatim, so both paths can hold spaces.
        let line = format!(r#"/d /s /c ""{}" /update >> "{}" 2>&1""#, script.display(), log.display());
        Command::new(windir.join(r"System32\cmd.exe"))
            .raw_arg(line)
            .current_dir(&root)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP)
            .spawn()
            .map_err(|e| format!("starting install.cmd: {e}"))?;
        Ok(())
    }
}

fn log_path() -> PathBuf {
    let base = std::env::var_os("ProgramData").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
    base.join(r"Seemless\logs\tools-update.log")
}

/// `X:\` of the first drive whose volume label equals `label`.
fn find_volume(label: &str) -> Option<PathBuf> {
    let mask = unsafe { GetLogicalDrives() };
    for i in 0..26u32 {
        if mask & (1 << i) == 0 {
            continue;
        }
        let root = format!("{}:\\", (b'A' + i as u8) as char);
        let w = wide(&root);
        let mut name = [0u16; 64];
        let ok = unsafe {
            GetVolumeInformationW(
                w.as_ptr(),
                name.as_mut_ptr(),
                name.len() as u32,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                0,
            )
        } != 0;
        if !ok {
            continue; // empty drive, network drive that is gone, ...
        }
        let end = name.iter().position(|&c| c == 0).unwrap_or(name.len());
        if String::from_utf16_lossy(&name[..end]).eq_ignore_ascii_case(label) {
            return Some(PathBuf::from(root));
        }
    }
    None
}
