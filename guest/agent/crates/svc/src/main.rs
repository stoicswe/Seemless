//! LocalSystem Windows service: owns the virtio-serial ports and supervises the session agent (docs/06).

#[cfg(windows)]
fn main() {}

#[cfg(not(windows))]
fn main() {
    eprintln!("seemless-agent-svc runs only on Windows (build with --target aarch64-pc-windows-msvc)");
    std::process::exit(1);
}
