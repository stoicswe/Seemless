//! `GuestInfo` from the registry (docs/06 "Session and system").
//!
//! - `os_build`: product name, display version and `CurrentBuild.UBR` from
//!   `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`.
//! - `gpu_adapter`: `DriverDesc` of each Display-class device.
//! - `driver_versions`: Display devices plus every VirtIO / Red Hat driver
//!   in the System, Net and SCSI adapter classes, from the class keys'
//!   `DriverDesc` and `DriverVersion`.
//!
//! Strings are capped before they leave the guest (the host caps them again).

use std::ptr::null_mut;

use proto::v1::{DriverVersion, GuestInfo};
use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW, HKEY, HKEY_LOCAL_MACHINE, KEY_READ, RRF_RT_REG_DWORD, RRF_RT_REG_SZ,
};

use transport::win::wide;

const CURRENT_VERSION: &str = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
const CLASS: &str = r"SYSTEM\CurrentControlSet\Control\Class";
const DISPLAY: &str = "{4d36e968-e325-11ce-bfc1-08002be10318}";
const SYSTEM: &str = "{4d36e97d-e325-11ce-bfc1-08002be10318}";
const NET: &str = "{4d36e972-e325-11ce-bfc1-08002be10318}";
const SCSI: &str = "{4d36e97b-e325-11ce-bfc1-08002be10318}";
const MAX_DRIVERS: usize = 32;
const MAX_TEXT: usize = 128;

fn reg_string(key: &str, value: &str) -> Option<String> {
    let k = wide(key);
    let v = wide(value);
    let mut buf = vec![0u16; 512];
    let mut bytes = (buf.len() * 2) as u32;
    let r = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, k.as_ptr(), v.as_ptr(), RRF_RT_REG_SZ, null_mut(), buf.as_mut_ptr().cast(), &mut bytes) };
    if r != ERROR_SUCCESS {
        return None;
    }
    let len = (bytes as usize / 2).saturating_sub(1);
    Some(String::from_utf16_lossy(&buf[..len.min(buf.len())]))
}

fn reg_dword(key: &str, value: &str) -> Option<u32> {
    let k = wide(key);
    let v = wide(value);
    let mut out = 0u32;
    let mut bytes = 4u32;
    let r = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, k.as_ptr(), v.as_ptr(), RRF_RT_REG_DWORD, null_mut(), (&mut out as *mut u32).cast(), &mut bytes) };
    (r == ERROR_SUCCESS).then_some(out)
}

fn subkeys(key: &str) -> Vec<String> {
    let k = wide(key);
    let mut h: HKEY = null_mut();
    if unsafe { RegOpenKeyExW(HKEY_LOCAL_MACHINE, k.as_ptr(), 0, KEY_READ, &mut h) } != ERROR_SUCCESS {
        return Vec::new();
    }
    let mut names = Vec::new();
    for i in 0..10_000u32 {
        let mut buf = [0u16; 256];
        let mut len = buf.len() as u32;
        let r = unsafe { RegEnumKeyExW(h, i, buf.as_mut_ptr(), &mut len, null_mut(), null_mut(), null_mut(), null_mut()) };
        if r != ERROR_SUCCESS {
            break;
        }
        names.push(String::from_utf16_lossy(&buf[..len as usize]));
    }
    unsafe { RegCloseKey(h) };
    names
}

fn cap(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).take(MAX_TEXT).collect()
}

/// `(DriverDesc, DriverVersion, ProviderName)` for each device of a class.
fn class_drivers(class: &str) -> Vec<(String, String, String)> {
    let base = format!(r"{CLASS}\{class}");
    subkeys(&base)
        .into_iter()
        .filter(|n| n.len() == 4 && n.bytes().all(|b| b.is_ascii_digit()))
        .filter_map(|n| {
            let key = format!(r"{base}\{n}");
            let desc = reg_string(&key, "DriverDesc")?;
            let version = reg_string(&key, "DriverVersion").unwrap_or_default();
            let provider = reg_string(&key, "ProviderName").unwrap_or_default();
            Some((desc, version, provider))
        })
        .collect()
}

fn os_build() -> String {
    let build = reg_string(CURRENT_VERSION, "CurrentBuild").unwrap_or_default();
    let ubr = reg_dword(CURRENT_VERSION, "UBR").unwrap_or(0);
    let mut product = reg_string(CURRENT_VERSION, "ProductName").unwrap_or_else(|| "Windows".into());
    // ProductName still says "Windows 10" on Windows 11.
    if build.parse::<u32>().unwrap_or(0) >= 22000 {
        product = product.replacen("Windows 10", "Windows 11", 1);
    }
    let display = reg_string(CURRENT_VERSION, "DisplayVersion").unwrap_or_default();
    cap(&format!("{product} {display} (10.0.{build}.{ubr})").replace("  ", " "))
}

pub fn guest_info(agent_version: &str) -> GuestInfo {
    let display = class_drivers(DISPLAY);
    let gpu_adapter = cap(&display.iter().map(|d| d.0.as_str()).collect::<Vec<_>>().join("; "));
    let mut drivers: Vec<DriverVersion> = display.iter().map(|d| DriverVersion { name: cap(&d.0), version: cap(&d.1) }).collect();
    for class in [SYSTEM, NET, SCSI] {
        for (desc, version, provider) in class_drivers(class) {
            let virtio = desc.to_ascii_lowercase().contains("virtio") || provider.contains("Red Hat");
            if virtio {
                drivers.push(DriverVersion { name: cap(&desc), version: cap(&version) });
            }
        }
    }
    drivers.dedup_by(|a, b| a.name == b.name && a.version == b.version);
    drivers.truncate(MAX_DRIVERS);
    GuestInfo { os_build: os_build(), driver_versions: drivers, agent_version: cap(agent_version), gpu_adapter }
}
