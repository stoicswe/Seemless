//! Per-user session agent: windows, capture, input assist, clipboard, shell integration (docs/06).
//!
//! Started by the service as `seemless-agent.exe --pipe <path>`. Exits when
//! the pipe closes; the service starts a new one.
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
fn main() {
    use std::sync::mpsc;
    use proto::frame::Channel;
    use session::{Action, Core};
    use transport::link::{self, Received, Writer};
    use transport::log::{log, log_to_file};

    if let Some(dir) = std::env::var_os("LOCALAPPDATA") {
        let _ = log_to_file(&std::path::Path::new(&dir).join(r"Seemless\logs\agent.log"));
    }
    let args: Vec<String> = std::env::args().collect();
    let Some(pipe) = args.iter().position(|a| a == "--pipe").and_then(|i| args.get(i + 1)) else {
        log("usage: seemless-agent --pipe <path> (the service starts this)");
        std::process::exit(2);
    };
    let mut build = format!("seemless-agent {}", env!("CARGO_PKG_VERSION"));
    if let Some(rev) = option_env!("SEEMLESS_AGENT_REV") {
        build.push_str(&format!(" ({rev})"));
    }
    let d = match transport::win::pipe_connect(pipe) {
        Ok(d) => d,
        Err(e) => {
            log(&format!("cannot open {pipe}: {e}"));
            std::process::exit(1);
        }
    };
    let (tx, rx) = mpsc::channel();
    let writer = Writer::spawn("pipe", d.writer, |e| log(&format!("pipe write failed: {e}"))).expect("writer thread");
    link::spawn_reader("pipe", d.reader, Channel::Control, tx, |r| r).expect("reader thread");
    let mut core = Core::new(build.clone());
    log(&format!("{build} connected to {pipe}"));
    let mut actions = core.connected();
    loop {
        for a in actions.drain(..) {
            match a {
                Action::Send(env) => {
                    writer.send(&env);
                }
                Action::Log(line) => log(&line),
                Action::Disconnect(why) => {
                    log(&format!("disconnecting: {why}"));
                    (d.close)();
                    std::process::exit(1);
                }
            }
        }
        match rx.recv() {
            Ok(Received::Envelope(env)) => actions = core.handle(env),
            Ok(Received::Reset(why)) | Ok(Received::Closed(why)) => {
                log(&format!("pipe closed: {why}"));
                std::process::exit(0);
            }
            Err(_) => std::process::exit(0),
        }
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("seemless-agent runs only on Windows (build with --target aarch64-pc-windows-msvc)");
    std::process::exit(1);
}
