//! Per-user session agent: windows, capture, input assist, clipboard, shell integration (docs/06).

#[cfg(windows)]
fn main() {}

#[cfg(not(windows))]
fn main() {
    eprintln!("seemless-agent runs only on Windows (build with --target aarch64-pc-windows-msvc)");
    std::process::exit(1);
}
