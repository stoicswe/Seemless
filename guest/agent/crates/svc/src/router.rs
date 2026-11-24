//! The service's message router (docs/06 "Agent processes").
//!
//! Sans-IO: [`Router::handle`] takes one [`Input`] and returns what to send
//! where. The Windows I/O loop (`run.rs`) and the Mac tests drive the same
//! code.
//!
//! - **Host link** (virtio-serial). The service is the only guest endpoint
//!   the host ever sees. It answers `Hello`, `Ping` and `GetGuestInfo`
//!   itself, replies `UNSUPPORTED` to system requests that are not built
//!   yet, and forwards every other host request to the session agent.
//! - **Session link** (named pipe). Same framing and `Envelope`s. The
//!   session agent opens with `Hello` (role `GUEST_SERVICE`); the service
//!   answers with a `Hello` of role `HOST`, then forwards the host's
//!   current `Hello` so the agent knows the host is there and what it
//!   negotiated. Each host (re)connect is forwarded the same way: the
//!   session agent then sends its full state (`WindowSnapshot`).
//!
//! Sequence numbers are per link. A host request forwarded to the session
//! gets a pipe seq; the reply is mapped back to the host's seq. A session
//! request to the host (`OpenOnHost`, `ClipboardRequest`) is mapped the
//! other way. Mappings die with either link.
//!
//! The service advertises `core.v1` plus the capabilities of the connected
//! session agent. When that set changes, it sends the host a fresh `Hello`,
//! which the host treats as an agent restart (docs/06 "Handshake").

use std::collections::HashMap;

use proto::handshake::{self, capability, Negotiated};
use proto::v1::envelope::Body;
use proto::v1::{
    error, shutdown, Ack, Envelope, Error as ProtoError, GuestInfo, Hello, Pong, Role, SessionState, SetHostInfo, TimeSync,
    UpdateTools,
};

/// Requests in flight across the service, per direction.
pub const MAX_PENDING: usize = 1024;

/// Longest `UpdateTools.iso_volume_label` accepted (ISO 9660 allows 32).
pub const MAX_VOLUME_LABEL: usize = 32;
/// Longest `UpdateTools.version` accepted.
pub const MAX_TOOLS_VERSION: usize = 64;

/// What the router asks of the machine: the registry and processes on
/// Windows, fixtures in tests. Every method gets arguments the router has
/// already validated, and must return quickly (start work, don't wait).
pub trait System {
    fn guest_info(&self) -> GuestInfo;

    /// Starts the tools update from the volume labelled `label`, whose
    /// `version.txt` must read `version` (docs/06 "Guest tools ISO").
    /// `Err` is the reason the update did not start.
    fn update_tools(&mut self, label: &str, version: &str) -> Result<(), String> {
        let _ = (label, version);
        Err("tools updates are not supported here".into())
    }

    /// Sets the system clock to `unix_nanos` (already range-checked).
    fn set_time(&mut self, unix_nanos: i64) -> Result<(), String> {
        let _ = unix_nanos;
        Err("setting the clock is not supported here".into())
    }

    /// Starts a shutdown, restart or sign-out a moment from now (so the
    /// `Ack` can leave first). Hibernate never reaches this (docs/06).
    fn shutdown(&mut self, mode: shutdown::Mode) -> Result<(), String> {
        let _ = mode;
        Err("shutdown is not supported here".into())
    }
}

/// A closure that returns `GuestInfo` is a `System` with nothing else (tests).
impl<F: Fn() -> GuestInfo> System for F {
    fn guest_info(&self) -> GuestInfo {
        self()
    }
}

/// Earliest and latest clock a `TimeSync` may set (2020-01-01, 2200-01-01).
pub const MIN_TIME_NANOS: i64 = 1_577_836_800 * 1_000_000_000;
pub const MAX_TIME_NANOS: i64 = 7_258_118_400 * 1_000_000_000;
/// Bounds on `SetHostInfo` (host data, but bounded like everything else).
pub const MAX_HOST_DISPLAYS: usize = 16;
pub const MAX_HOST_INFO_TEXT: usize = 128;

pub fn validate_time_sync(t: &TimeSync) -> Result<(), String> {
    if (MIN_TIME_NANOS..=MAX_TIME_NANOS).contains(&t.unix_nanos) {
        Ok(())
    } else {
        Err(format!("time {} ns is outside 2020-2200", t.unix_nanos))
    }
}

pub fn validate_host_info(h: &SetHostInfo) -> Result<(), String> {
    if h.displays.len() > MAX_HOST_DISPLAYS {
        return Err(format!("at most {MAX_HOST_DISPLAYS} displays"));
    }
    for (what, text) in [("locale", &h.locale), ("keyboard_layout", &h.keyboard_layout), ("timezone", &h.timezone)] {
        if text.len() > MAX_HOST_INFO_TEXT || text.chars().any(char::is_control) {
            return Err(format!("{what} must be at most {MAX_HOST_INFO_TEXT} printable characters"));
        }
    }
    if !(h.scale == 0.0 || (0.5..=8.0).contains(&h.scale)) {
        return Err("scale must be 0 (unknown) or 0.5-8".into());
    }
    Ok(())
}

/// Checks a host `UpdateTools` before anything touches the disk.
pub fn validate_update_tools(u: &UpdateTools) -> Result<(), String> {
    let label = &u.iso_volume_label;
    if label.is_empty() || label.len() > MAX_VOLUME_LABEL {
        return Err(format!("volume label must be 1-{MAX_VOLUME_LABEL} characters"));
    }
    if !label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
        return Err("volume label may only hold A-Z, a-z, 0-9, '_' and '-'".into());
    }
    let v = &u.version;
    if v.is_empty() || v.len() > MAX_TOOLS_VERSION {
        return Err(format!("version must be 1-{MAX_TOOLS_VERSION} characters"));
    }
    if !v.bytes().all(|b| (0x20..0x7f).contains(&b)) {
        return Err("version must be printable ASCII".into());
    }
    Ok(())
}

#[derive(Debug)]
pub enum Input {
    /// A decoded envelope from the host.
    Host(Envelope),
    /// The host link was reset (framing error, port reopened).
    HostReset,
    /// A session agent connected to the pipe (its process was checked).
    SessionConnected,
    Session(Envelope),
    SessionClosed,
    /// The console session now (polled by the service every few seconds).
    SessionState(SessionState),
}

#[derive(Debug, PartialEq)]
pub enum Output {
    Host(Envelope),
    Session(Envelope),
    /// Drop the session agent's pipe connection (protocol violation).
    CloseSession(String),
    /// Something worth a line in the service log.
    Log(String),
}

#[derive(Debug)]
enum SessionLink {
    None,
    AwaitingHello,
    Ready,
}

pub struct Router {
    build: String,
    system: Box<dyn System + Send>,
    host_seq: u64,
    /// The host's Hello on the current connection, once received.
    host_hello: Option<Hello>,
    host_negotiated: Option<Negotiated>,
    /// Capabilities in the last Hello we sent the host.
    advertised: Vec<String>,
    /// The console session as last reported by the machine.
    session_state: Option<SessionState>,
    /// The host's last `SetHostInfo`, replayed to each new session agent.
    host_info: Option<SetHostInfo>,
    session: SessionLink,
    session_seq: u64,
    /// pipe seq of a forwarded host request → host seq.
    to_session: HashMap<u64, u64>,
    /// host seq of a forwarded session request → pipe seq.
    to_host: HashMap<u64, u64>,
}

impl Router {
    pub fn new(build: impl Into<String>, system: impl System + Send + 'static) -> Self {
        Self {
            build: build.into(),
            system: Box::new(system),
            host_seq: 0,
            host_hello: None,
            host_negotiated: None,
            advertised: base_capabilities(),
            session_state: None,
            host_info: None,
            session: SessionLink::None,
            session_seq: 0,
            to_session: HashMap::new(),
            to_host: HashMap::new(),
        }
    }

    /// The host's side of the handshake on the current connection.
    pub fn host(&self) -> Option<&Negotiated> {
        self.host_negotiated.as_ref()
    }

    pub fn session_ready(&self) -> bool {
        matches!(self.session, SessionLink::Ready)
    }

    /// What to send when the host port opens: our Hello. virtio-serial drops
    /// it if the host is not connected; the host's own Hello then gets one.
    pub fn start(&mut self) -> Vec<Output> {
        self.host_seq = 0;
        vec![Output::Host(self.host_envelope(0, Body::Hello(self.local_hello())))]
    }

    pub fn handle(&mut self, input: Input) -> Vec<Output> {
        let mut out = Vec::new();
        match input {
            Input::Host(env) => self.on_host(env, &mut out),
            Input::HostReset => {
                self.drop_host_connection(&mut out);
                out.extend(self.start());
            }
            Input::SessionConnected => {
                self.drop_session(&mut out, "replaced by a new session agent");
                self.session = SessionLink::AwaitingHello;
                self.session_seq = 0;
            }
            Input::Session(env) => self.on_session(env, &mut out),
            Input::SessionClosed => self.drop_session(&mut out, "session agent exited"),
            Input::SessionState(state) => {
                if self.session_state.as_ref() != Some(&state) {
                    out.push(Output::Log(format!(
                        "console session: logged_on={} locked={} user={:?}",
                        state.logged_on, state.locked, state.user
                    )));
                    self.session_state = Some(state);
                    self.send_session_state(&mut out);
                }
            }
        }
        out
    }

    // MARK: host link

    fn local_hello(&self) -> Hello {
        let caps: Vec<&str> = self.advertised.iter().map(String::as_str).collect();
        handshake::hello(Role::GuestService, &self.build, &caps)
    }

    fn next_host_seq(&mut self) -> u64 {
        self.host_seq += 1;
        self.host_seq
    }

    fn host_envelope(&mut self, reply_to: u64, body: Body) -> Envelope {
        let seq = self.next_host_seq();
        Envelope { seq, reply_to, body: Some(body) }
    }

    fn reply_host(&mut self, out: &mut Vec<Output>, request: u64, body: Body) {
        let env = self.host_envelope(request, body);
        out.push(Output::Host(env));
    }

    fn unsupported(what: &str) -> Body {
        Body::Error(ProtoError { code: error::Code::Unsupported as i32, message: format!("{what} is not supported by this agent") })
    }

    /// Forgets everything tied to the host connection (seqs, mappings).
    fn drop_host_connection(&mut self, out: &mut Vec<Output>) {
        self.host_hello = None;
        self.host_negotiated = None;
        // Host requests the session is still working on: their replies have
        // nowhere to go. Session requests to the host: fail them.
        self.to_session.clear();
        let waiting: Vec<u64> = self.to_host.drain().map(|(_, s)| s).collect();
        for pipe_seq in waiting {
            let body = Body::Error(ProtoError { code: error::Code::Internal as i32, message: "host disconnected".into() });
            self.reply_session(out, pipe_seq, body);
        }
    }

    fn on_host(&mut self, env: Envelope, out: &mut Vec<Output>) {
        let Some(body) = env.body else {
            // A body this build does not know (newer minor): ignored (docs/06).
            return;
        };
        if let Body::Hello(hello) = body {
            if env.reply_to == 0 {
                // A new host connection (or the host restarted): fresh seqs.
                self.drop_host_connection(out);
                self.host_seq = 0;
                let ours = self.local_hello();
                self.reply_host(out, env.seq, Body::Hello(ours));
            }
            self.accept_host_hello(hello, out);
            return;
        }
        if self.host_negotiated.is_none() {
            out.push(Output::Log(format!("host message before a valid Hello dropped (seq {})", env.seq)));
            return;
        }
        if env.reply_to != 0 {
            // A reply to one of the session's requests; anything else is dropped.
            if let Some(pipe_seq) = self.to_host.remove(&env.reply_to) {
                self.reply_session(out, pipe_seq, body);
            }
            return;
        }
        match body {
            Body::Ping(p) => self.reply_host(out, env.seq, Body::Pong(Pong { nonce: p.nonce })),
            Body::GetGuestInfo(_) => {
                let info = self.system.guest_info();
                self.reply_host(out, env.seq, Body::GuestInfo(info));
            }
            Body::UpdateTools(u) => {
                let reply = match validate_update_tools(&u) {
                    Err(why) => Body::Error(ProtoError { code: error::Code::Invalid as i32, message: why }),
                    Ok(()) => match self.system.update_tools(&u.iso_volume_label, &u.version) {
                        Ok(()) => {
                            out.push(Output::Log(format!("tools update to {} started from volume {}", u.version, u.iso_volume_label)));
                            Body::Ack(Ack {})
                        }
                        Err(why) => {
                            out.push(Output::Log(format!("tools update to {} not started: {why}", u.version)));
                            Body::Error(ProtoError { code: error::Code::Internal as i32, message: why })
                        }
                    },
                };
                self.reply_host(out, env.seq, reply);
            }
            Body::TimeSync(t) => {
                let reply = match validate_time_sync(&t) {
                    Err(why) => Body::Error(ProtoError { code: error::Code::Invalid as i32, message: why }),
                    Ok(()) => match self.system.set_time(t.unix_nanos) {
                        Ok(()) => Body::Ack(Ack {}),
                        Err(why) => Body::Error(ProtoError { code: error::Code::Internal as i32, message: why }),
                    },
                };
                self.reply_host(out, env.seq, reply);
            }
            Body::Shutdown(sd) => {
                let reply = match shutdown::Mode::try_from(sd.mode) {
                    Ok(shutdown::Mode::Hibernate) => Self::unsupported("Shutdown HIBERNATE"),
                    Ok(mode @ (shutdown::Mode::Shutdown | shutdown::Mode::Restart | shutdown::Mode::Logoff)) => {
                        match self.system.shutdown(mode) {
                            Ok(()) => {
                                out.push(Output::Log(format!("host asked for {}", mode.as_str_name())));
                                Body::Ack(Ack {})
                            }
                            Err(why) => Body::Error(ProtoError { code: error::Code::Internal as i32, message: why }),
                        }
                    }
                    _ => Body::Error(ProtoError { code: error::Code::Invalid as i32, message: format!("unknown shutdown mode {}", sd.mode) }),
                };
                self.reply_host(out, env.seq, reply);
            }
            Body::SetHostInfo(h) => {
                let reply = match validate_host_info(&h) {
                    Ok(()) => {
                        // Applied by the session agent (theme is per user);
                        // kept for the next one if none is running.
                        self.host_info = Some(h);
                        self.send_host_info(out);
                        Body::Ack(Ack {})
                    }
                    Err(why) => Body::Error(ProtoError { code: error::Code::Invalid as i32, message: why }),
                };
                self.reply_host(out, env.seq, reply);
            }
            Body::RunCommand(_) => self.reply_host(out, env.seq, Self::unsupported("RunCommand")),
            body if is_session_request(&body) => self.forward_to_session(env.seq, body, out),
            // Pong, or a guest→host message sent the wrong way.
            _ => {}
        }
    }

    fn accept_host_hello(&mut self, hello: Hello, out: &mut Vec<Output>) {
        match handshake::negotiate(&self.local_hello(), &hello) {
            Ok(n) => {
                out.push(Output::Log(format!(
                    "host {} (protocol {}.{}), capabilities [{}]",
                    n.peer_build,
                    n.peer_major,
                    n.peer_minor,
                    n.capabilities.join(", ")
                )));
                self.host_negotiated = Some(n);
                self.host_hello = Some(hello);
                self.announce_host_to_session(out);
                // A new host learns the console session right away (the
                // offline first setup waits for a signed-in desktop).
                self.send_session_state(out);
            }
            Err(e) => {
                // Our Hello still went out, so the host sees the mismatch too
                // and can offer a tools update.
                out.push(Output::Log(format!("host Hello rejected: {e}")));
                self.host_negotiated = None;
                self.host_hello = None;
            }
        }
    }

    fn send_session_state(&mut self, out: &mut Vec<Output>) {
        if self.host_negotiated.is_none() {
            return;
        }
        if let Some(state) = self.session_state.clone() {
            let env = self.host_envelope(0, Body::SessionState(state));
            out.push(Output::Host(env));
        }
    }

    /// Sends the stored `SetHostInfo` to the session agent as a request of
    /// the service's own; its reply matches no host request and is dropped.
    fn send_host_info(&mut self, out: &mut Vec<Output>) {
        if !self.session_ready() {
            return;
        }
        if let Some(h) = self.host_info.clone() {
            let seq = self.next_session_seq();
            out.push(Output::Session(Envelope { seq, reply_to: 0, body: Some(Body::SetHostInfo(h)) }));
        }
    }

    fn forward_to_session(&mut self, host_seq: u64, body: Body, out: &mut Vec<Output>) {
        if !self.session_ready() {
            self.reply_host(out, host_seq, Self::unsupported("this request (no session agent is running)"));
            return;
        }
        if self.to_session.len() >= MAX_PENDING {
            let busy = Body::Error(ProtoError { code: error::Code::Busy as i32, message: "too many requests in flight".into() });
            self.reply_host(out, host_seq, busy);
            return;
        }
        let pipe_seq = self.next_session_seq();
        self.to_session.insert(pipe_seq, host_seq);
        out.push(Output::Session(Envelope { seq: pipe_seq, reply_to: 0, body: Some(body) }));
    }

    // MARK: session link

    fn next_session_seq(&mut self) -> u64 {
        self.session_seq += 1;
        self.session_seq
    }

    fn reply_session(&mut self, out: &mut Vec<Output>, request: u64, body: Body) {
        let seq = self.next_session_seq();
        out.push(Output::Session(Envelope { seq, reply_to: request, body: Some(body) }));
    }

    fn pipe_hello(&self) -> Hello {
        handshake::hello(Role::Host, &self.build, &session_capabilities())
    }

    fn announce_host_to_session(&mut self, out: &mut Vec<Output>) {
        if !self.session_ready() {
            return;
        }
        if let Some(hello) = self.host_hello.clone() {
            let seq = self.next_session_seq();
            out.push(Output::Session(Envelope { seq, reply_to: 0, body: Some(Body::Hello(hello)) }));
        }
    }

    fn drop_session(&mut self, out: &mut Vec<Output>, why: &str) {
        let was_ready = self.session_ready();
        if matches!(self.session, SessionLink::None) {
            return;
        }
        self.session = SessionLink::None;
        self.to_host.clear();
        let waiting: Vec<u64> = self.to_session.drain().map(|(_, h)| h).collect();
        for host_seq in waiting {
            let body = Body::Error(ProtoError { code: error::Code::Internal as i32, message: why.to_owned() });
            self.reply_host(out, host_seq, body);
        }
        out.push(Output::Log(why.to_owned()));
        if was_ready {
            self.set_advertised(base_capabilities(), out);
        }
    }

    /// Sends the host a fresh Hello when the advertised set changes.
    fn set_advertised(&mut self, mut caps: Vec<String>, out: &mut Vec<Output>) {
        caps.sort();
        caps.dedup();
        if caps == self.advertised {
            return;
        }
        self.advertised = caps;
        if self.host_negotiated.is_some() {
            let hello = self.local_hello();
            let env = self.host_envelope(0, Body::Hello(hello));
            out.push(Output::Host(env));
        }
    }

    fn on_session(&mut self, env: Envelope, out: &mut Vec<Output>) {
        match &self.session {
            SessionLink::None => {}
            SessionLink::AwaitingHello => match env.body {
                Some(Body::Hello(hello)) if env.reply_to == 0 => match handshake::negotiate(&self.pipe_hello(), &hello) {
                    Ok(n) if n.peer_major == handshake::PROTOCOL_MAJOR && n.peer_minor == handshake::PROTOCOL_MINOR => {
                        let caps = n.capabilities.clone();
                        out.push(Output::Log(format!("session agent {} ready, capabilities [{}]", n.peer_build, caps.join(", "))));
                        self.session = SessionLink::Ready;
                        let ours = self.pipe_hello();
                        self.reply_session(out, env.seq, Body::Hello(ours));
                        let mut all = base_capabilities();
                        all.extend(caps);
                        self.set_advertised(all, out);
                        self.announce_host_to_session(out);
                        self.send_host_info(out);
                    }
                    Ok(n) => out.push(Output::CloseSession(format!(
                        "session agent speaks {}.{}, the service {}.{}: install matching guest tools",
                        n.peer_major,
                        n.peer_minor,
                        handshake::PROTOCOL_MAJOR,
                        handshake::PROTOCOL_MINOR
                    ))),
                    Err(e) => out.push(Output::CloseSession(format!("session Hello rejected: {e}"))),
                },
                _ => out.push(Output::CloseSession("session agent must start with Hello".into())),
            },
            SessionLink::Ready => {
                let Some(body) = env.body else { return };
                if env.reply_to != 0 {
                    let Some(host_seq) = self.to_session.remove(&env.reply_to) else { return };
                    if is_session_reply(&body) {
                        self.reply_host(out, host_seq, body);
                    } else {
                        let bad = Body::Error(ProtoError { code: error::Code::Internal as i32, message: "bad reply from the session agent".into() });
                        self.reply_host(out, host_seq, bad);
                        out.push(Output::Log("session agent sent a non-reply message as a reply".into()));
                    }
                    return;
                }
                if self.host_negotiated.is_none() {
                    // No host: events are lost, the agent resends its state on
                    // the next host Hello. Requests fail now.
                    if is_session_host_request(&body) {
                        let e = Body::Error(ProtoError { code: error::Code::Unsupported as i32, message: "host not connected".into() });
                        self.reply_session(out, env.seq, e);
                    }
                    return;
                }
                if is_session_host_request(&body) {
                    if self.to_host.len() >= MAX_PENDING {
                        let e = Body::Error(ProtoError { code: error::Code::Busy as i32, message: "too many requests in flight".into() });
                        self.reply_session(out, env.seq, e);
                        return;
                    }
                    let host_env = self.host_envelope(0, body);
                    self.to_host.insert(host_env.seq, env.seq);
                    out.push(Output::Host(host_env));
                } else if is_session_event(&body) {
                    let host_env = self.host_envelope(0, body);
                    out.push(Output::Host(host_env));
                } else {
                    out.push(Output::Log(format!("session agent message not allowed: {}", body_name(&body))));
                }
            }
        }
    }
}

/// What the service itself implements: core and the system family
/// (GuestInfo, UpdateTools, TimeSync, Shutdown, SetHostInfo, SessionState).
fn base_capabilities() -> Vec<String> {
    let mut caps = vec![capability::CORE.to_owned(), capability::SYSTEM.to_owned()];
    caps.sort();
    caps
}

/// Capabilities the session agent may claim. Others are not forwarded.
fn session_capabilities() -> Vec<&'static str> {
    vec![capability::WINDOWS, capability::APPS, capability::CLIPBOARD, capability::DRAG_DROP]
}

/// Host requests the session agent answers.
fn is_session_request(body: &Body) -> bool {
    matches!(
        body,
        Body::PointerFocus(_)
            | Body::Activate(_)
            | Body::Deactivate(_)
            | Body::SetWindowRect(_)
            | Body::WindowCommand(_)
            | Body::HitTest(_)
            | Body::ListApps(_)
            | Body::GetIcon(_)
            | Body::Launch(_)
            | Body::TrayInvoke(_)
            | Body::ClipboardOffer(_)
            | Body::ClipboardRequest(_)
            | Body::DragEnter(_)
            | Body::DragMove(_)
            | Body::DragLeave(_)
            | Body::Drop(_)
    )
}

/// What the session agent may send as a reply to a forwarded request.
fn is_session_reply(body: &Body) -> bool {
    matches!(
        body,
        Body::Ack(_) | Body::Error(_) | Body::HitTestResult(_) | Body::AppList(_) | Body::BulkOffer(_) | Body::Activated(_)
    )
}

/// Session → host events.
fn is_session_event(body: &Body) -> bool {
    matches!(
        body,
        Body::WindowSnapshot(_)
            | Body::WindowAdded(_)
            | Body::WindowUpdated(_)
            | Body::WindowRemoved(_)
            | Body::AtlasFrame(_)
            | Body::ForegroundChanged(_)
            | Body::CursorState(_)
            | Body::FullscreenState(_)
            | Body::AppsChanged(_)
            | Body::Notification(_)
            | Body::TrayItems(_)
            | Body::ClipboardOffer(_)
            | Body::DragStart(_)
    )
}

/// Session → host requests (the host replies).
fn is_session_host_request(body: &Body) -> bool {
    matches!(body, Body::OpenOnHost(_) | Body::ClipboardRequest(_))
}

fn body_name(body: &Body) -> &'static str {
    match body {
        Body::Hello(_) => "Hello",
        Body::Ping(_) => "Ping",
        Body::Pong(_) => "Pong",
        Body::SessionState(_) => "SessionState",
        Body::GuestInfo(_) => "GuestInfo",
        _ => "message",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::v1::{Ack, Appearance, GetGuestInfo, ListApps, OpenOnHost, Ping, Shutdown, WindowSnapshot};

    fn info() -> GuestInfo {
        GuestInfo { os_build: "10.0.26300.1".into(), agent_version: "test".into(), ..Default::default() }
    }

    fn router() -> Router {
        Router::new("seemless-agent-svc test", info)
    }

    fn host_hello() -> Hello {
        handshake::hello(Role::Host, "host", &[capability::CORE, capability::WINDOWS, capability::APPS])
    }

    fn session_hello(caps: &[&str]) -> Hello {
        handshake::hello(Role::GuestService, "seemless-agent test", caps)
    }

    fn env(seq: u64, reply_to: u64, body: Body) -> Envelope {
        Envelope { seq, reply_to, body: Some(body) }
    }

    fn to_host(out: &[Output]) -> Vec<&Envelope> {
        out.iter().filter_map(|o| if let Output::Host(e) = o { Some(e) } else { None }).collect()
    }

    fn to_session(out: &[Output]) -> Vec<&Envelope> {
        out.iter().filter_map(|o| if let Output::Session(e) = o { Some(e) } else { None }).collect()
    }

    fn connected() -> Router {
        let mut r = router();
        r.start();
        r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        r
    }

    fn with_session(caps: &[&str]) -> Router {
        let mut r = connected();
        r.handle(Input::SessionConnected);
        r.handle(Input::Session(env(1, 0, Body::Hello(session_hello(caps)))));
        r
    }

    #[test]
    fn answers_host_hello_and_negotiates() {
        let mut r = router();
        let start = r.start();
        let first = to_host(&start);
        assert_eq!((first[0].seq, first[0].reply_to), (1, 0));
        let out = r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        let h = to_host(&out);
        assert_eq!(h.len(), 1);
        // New host connection: our seqs start again at 1.
        assert_eq!((h[0].seq, h[0].reply_to), (1, 1));
        let Some(Body::Hello(ours)) = &h[0].body else { panic!() };
        assert_eq!(ours.role, Role::GuestService as i32);
        assert_eq!(ours.capabilities, ["core.v1", "system.v1"]);
        assert_eq!(r.host().unwrap().capabilities, ["core.v1"]);
    }

    #[test]
    fn hello_reply_is_not_answered() {
        let mut r = router();
        r.start();
        let out = r.handle(Input::Host(env(1, 1, Body::Hello(host_hello()))));
        assert!(to_host(&out).is_empty());
        assert!(r.host().is_some());
    }

    #[test]
    fn pings_and_guest_info() {
        let mut r = connected();
        let out = r.handle(Input::Host(env(2, 0, Body::Ping(Ping { nonce: 42 }))));
        assert_eq!(to_host(&out)[0].body, Some(Body::Pong(Pong { nonce: 42 })));
        assert_eq!(to_host(&out)[0].reply_to, 2);
        let out = r.handle(Input::Host(env(3, 0, Body::GetGuestInfo(GetGuestInfo {}))));
        assert_eq!(to_host(&out)[0].body, Some(Body::GuestInfo(info())));
        assert_eq!(to_host(&out)[0].reply_to, 3);
    }

    #[test]
    fn nothing_before_hello_and_bad_hello_still_answered() {
        let mut r = router();
        r.start();
        assert!(to_host(&r.handle(Input::Host(env(1, 0, Body::Ping(Ping { nonce: 1 }))))).is_empty());
        let mut bad = host_hello();
        bad.protocol_major = 9;
        let out = r.handle(Input::Host(env(2, 0, Body::Hello(bad))));
        assert_eq!(to_host(&out).len(), 1, "our Hello goes out so the host sees the mismatch");
        assert!(r.host().is_none());
        assert!(to_host(&r.handle(Input::Host(env(3, 0, Body::GetGuestInfo(GetGuestInfo {}))))).is_empty());
    }

    #[test]
    fn run_command_is_unsupported_for_now() {
        let mut r = connected();
        let out = r.handle(Input::Host(env(5, 0, Body::RunCommand(Default::default()))));
        let Some(Body::Error(e)) = &to_host(&out)[0].body else { panic!() };
        assert_eq!(e.code, error::Code::Unsupported as i32);
        assert_eq!(to_host(&out)[0].reply_to, 5);
    }

    #[derive(Default, Clone)]
    struct Calls(std::sync::Arc<std::sync::Mutex<Vec<String>>>);
    impl System for Calls {
        fn guest_info(&self) -> GuestInfo {
            info()
        }
        fn set_time(&mut self, unix_nanos: i64) -> Result<(), String> {
            self.0.lock().unwrap().push(format!("time {unix_nanos}"));
            Ok(())
        }
        fn shutdown(&mut self, mode: shutdown::Mode) -> Result<(), String> {
            self.0.lock().unwrap().push(format!("shutdown {}", mode.as_str_name()));
            Ok(())
        }
    }

    fn with_calls() -> (Router, Calls) {
        let calls = Calls::default();
        let mut r = Router::new("svc test", calls.clone());
        r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        (r, calls)
    }

    fn error_code(out: &[Output]) -> Option<i32> {
        match &to_host(out).last()?.body {
            Some(Body::Error(e)) => Some(e.code),
            _ => None,
        }
    }

    #[test]
    fn advertises_the_system_family() {
        let mut r = router();
        let out = r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        let Some(Body::Hello(h)) = &to_host(&out)[0].body else { panic!() };
        assert_eq!(h.capabilities, vec!["core.v1".to_owned(), "system.v1".to_owned()]);
    }

    #[test]
    fn time_sync_is_range_checked() {
        let (mut r, calls) = with_calls();
        for bad in [0, -1, MIN_TIME_NANOS - 1, MAX_TIME_NANOS + 1, i64::MAX] {
            let out = r.handle(Input::Host(env(2, 0, Body::TimeSync(TimeSync { unix_nanos: bad }))));
            assert_eq!(error_code(&out), Some(error::Code::Invalid as i32), "{bad}");
        }
        let now = 1_795_000_000 * 1_000_000_000;
        let out = r.handle(Input::Host(env(3, 0, Body::TimeSync(TimeSync { unix_nanos: now }))));
        assert!(matches!(to_host(&out)[0].body, Some(Body::Ack(_))));
        assert_eq!(calls.0.lock().unwrap().as_slice(), &[format!("time {now}")]);
        // A machine that cannot set the clock says so.
        let mut plain = connected();
        let out = plain.handle(Input::Host(env(4, 0, Body::TimeSync(TimeSync { unix_nanos: now }))));
        assert_eq!(error_code(&out), Some(error::Code::Internal as i32));
    }

    #[test]
    fn shutdown_modes() {
        let (mut r, calls) = with_calls();
        let sd = |m: shutdown::Mode| Body::Shutdown(Shutdown { mode: m as i32 });
        for (seq, m) in [(2, shutdown::Mode::Shutdown), (3, shutdown::Mode::Restart), (4, shutdown::Mode::Logoff)] {
            let out = r.handle(Input::Host(env(seq, 0, sd(m))));
            assert!(matches!(to_host(&out)[0].body, Some(Body::Ack(_))));
        }
        let out = r.handle(Input::Host(env(5, 0, sd(shutdown::Mode::Hibernate))));
        assert_eq!(error_code(&out), Some(error::Code::Unsupported as i32));
        for bad in [0, 99, -3] {
            let out = r.handle(Input::Host(env(6, 0, Body::Shutdown(Shutdown { mode: bad }))));
            assert_eq!(error_code(&out), Some(error::Code::Invalid as i32), "{bad}");
        }
        assert_eq!(calls.0.lock().unwrap().as_slice(), &["shutdown MODE_SHUTDOWN", "shutdown MODE_RESTART", "shutdown MODE_LOGOFF"]);
    }

    #[test]
    fn host_info_is_kept_and_replayed_to_each_session_agent() {
        let mut r = connected();
        let info = SetHostInfo { appearance: Appearance::Dark as i32, scale: 2.0, ..Default::default() };
        // No session agent: acked and kept.
        let out = r.handle(Input::Host(env(2, 0, Body::SetHostInfo(info.clone()))));
        assert!(matches!(to_host(&out)[0].body, Some(Body::Ack(_))));
        assert!(to_session(&out).is_empty());
        // A session agent connects: it gets the stored info after the handshake.
        r.handle(Input::SessionConnected);
        let out = r.handle(Input::Session(env(1, 0, Body::Hello(session_hello(&[])))));
        assert!(to_session(&out).iter().any(|e| e.body == Some(Body::SetHostInfo(info.clone())) && e.reply_to == 0));
        // Its reply matches no host request and is dropped.
        let sent = to_session(&out).iter().find(|e| matches!(e.body, Some(Body::SetHostInfo(_)))).unwrap().seq;
        let out = r.handle(Input::Session(env(2, sent, Body::Ack(Ack {}))));
        assert!(to_host(&out).is_empty());
        // A new SetHostInfo goes straight to the running agent.
        let light = SetHostInfo { appearance: Appearance::Light as i32, ..Default::default() };
        let out = r.handle(Input::Host(env(3, 0, Body::SetHostInfo(light.clone()))));
        assert!(to_session(&out).iter().any(|e| e.body == Some(Body::SetHostInfo(light.clone()))));
        // Bad input is refused.
        for bad in [
            SetHostInfo { locale: "x".repeat(129), ..Default::default() },
            SetHostInfo { timezone: "Europe/\nBerlin".into(), ..Default::default() },
            SetHostInfo { scale: 100.0, ..Default::default() },
            SetHostInfo { displays: vec![Default::default(); 17], ..Default::default() },
        ] {
            let out = r.handle(Input::Host(env(4, 0, Body::SetHostInfo(bad))));
            assert_eq!(error_code(&out), Some(error::Code::Invalid as i32));
        }
    }

    #[test]
    fn session_state_reaches_each_host_and_changes_are_sent_once() {
        let mut r = router();
        let state = SessionState { logged_on: true, locked: false, user: "Seemless".into(), secure_desktop: false };
        // Before any host: kept, nothing sent.
        let out = r.handle(Input::SessionState(state.clone()));
        assert!(to_host(&out).is_empty());
        // A host says Hello: our Hello reply, then the current state.
        let out = r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        let sent = to_host(&out);
        assert!(matches!(sent[0].body, Some(Body::Hello(_))));
        assert_eq!(sent[1].body, Some(Body::SessionState(state.clone())));
        assert_eq!(sent[1].reply_to, 0);
        // Same state again: nothing. A change: one event.
        assert!(to_host(&r.handle(Input::SessionState(state.clone()))).is_empty());
        let locked = SessionState { locked: true, ..state };
        let out = r.handle(Input::SessionState(locked.clone()));
        assert_eq!(to_host(&out)[0].body, Some(Body::SessionState(locked)));
    }

    struct Updater(std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>>, Result<(), String>);
    impl System for Updater {
        fn guest_info(&self) -> GuestInfo {
            info()
        }
        fn update_tools(&mut self, label: &str, version: &str) -> Result<(), String> {
            self.0.lock().unwrap().push((label.into(), version.into()));
            self.1.clone()
        }
    }

    fn update(label: &str, version: &str) -> Body {
        Body::UpdateTools(UpdateTools { iso_volume_label: label.into(), version: version.into() })
    }

    #[test]
    fn update_tools_is_validated_then_started() {
        let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut r = Router::new("svc test", Updater(calls.clone(), Ok(())));
        r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        for (seq, label, version) in [(2, "", "1"), (3, "SEEMLESS TOOLS", "1"), (4, "X:\\..", "1"), (5, "SEEMLESS_TOOLS", ""),
                                      (6, "SEEMLESS_TOOLS", "1\n2"), (7, &"L".repeat(33), "1"), (8, "SEEMLESS_TOOLS", &"9".repeat(65))] {
            let out = r.handle(Input::Host(env(seq, 0, update(label, version))));
            let Some(Body::Error(e)) = &to_host(&out)[0].body else { panic!("{label:?} {version:?} accepted") };
            assert_eq!(e.code, error::Code::Invalid as i32);
        }
        assert!(calls.lock().unwrap().is_empty(), "nothing invalid reaches the system");
        let out = r.handle(Input::Host(env(9, 0, update("SEEMLESS_TOOLS", "0.0.2 (abc)"))));
        assert!(matches!(to_host(&out)[0].body, Some(Body::Ack(_))));
        assert_eq!(to_host(&out)[0].reply_to, 9);
        assert_eq!(calls.lock().unwrap().as_slice(), &[("SEEMLESS_TOOLS".to_owned(), "0.0.2 (abc)".to_owned())]);
    }

    #[test]
    fn update_tools_failure_is_reported() {
        let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let mut r = Router::new("svc test", Updater(calls, Err("no volume labelled SEEMLESS_TOOLS".into())));
        r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        let out = r.handle(Input::Host(env(2, 0, update("SEEMLESS_TOOLS", "1"))));
        let Some(Body::Error(e)) = &to_host(&out)[0].body else { panic!() };
        assert_eq!(e.code, error::Code::Internal as i32);
        assert!(e.message.contains("no volume"));
        // The default System (a closure) has no updater.
        let mut r = connected();
        let out = r.handle(Input::Host(env(3, 0, update("SEEMLESS_TOOLS", "1"))));
        assert!(matches!(&to_host(&out)[0].body, Some(Body::Error(e)) if e.code == error::Code::Internal as i32));
    }

    #[test]
    fn unknown_bodies_are_ignored() {
        let mut r = connected();
        let out = r.handle(Input::Host(Envelope { seq: 9, reply_to: 0, body: None }));
        assert!(out.is_empty());
    }

    #[test]
    fn session_requests_without_a_session_are_unsupported() {
        let mut r = connected();
        let out = r.handle(Input::Host(env(4, 0, Body::ListApps(ListApps {}))));
        let Some(Body::Error(e)) = &to_host(&out)[0].body else { panic!() };
        assert_eq!(e.code, error::Code::Unsupported as i32);
    }

    #[test]
    fn session_handshake_rehellos_the_host_and_announces_it() {
        let mut r = connected();
        assert!(r.handle(Input::SessionConnected).is_empty());
        let out = r.handle(Input::Session(env(1, 0, Body::Hello(session_hello(&[capability::WINDOWS, "bogus.v1"])))));
        let s = to_session(&out);
        // Our pipe Hello (a reply), then the host's Hello.
        assert_eq!(s[0].reply_to, 1);
        let Some(Body::Hello(pipe)) = &s[0].body else { panic!() };
        assert_eq!(pipe.role, Role::Host as i32);
        assert_eq!(s[1].body, Some(Body::Hello(host_hello())));
        // The host gets a fresh Hello with the session's capabilities.
        let h = to_host(&out);
        assert_eq!(h.len(), 1);
        assert_eq!(h[0].reply_to, 0);
        let Some(Body::Hello(again)) = &h[0].body else { panic!() };
        assert_eq!(again.capabilities, ["core.v1", "system.v1", "windows.v1"]);
    }

    #[test]
    fn session_must_start_with_a_valid_hello() {
        let mut r = connected();
        r.handle(Input::SessionConnected);
        let out = r.handle(Input::Session(env(1, 0, Body::Ping(Ping { nonce: 1 }))));
        assert!(matches!(out[0], Output::CloseSession(_)));
        r.handle(Input::SessionConnected);
        let out = r.handle(Input::Session(env(1, 0, Body::Hello(handshake::hello(Role::Host, "x", &[])))));
        assert!(matches!(out[0], Output::CloseSession(_)));
        r.handle(Input::SessionConnected);
        let mut newer = session_hello(&[]);
        newer.protocol_minor = 1;
        let out = r.handle(Input::Session(env(1, 0, Body::Hello(newer))));
        assert!(matches!(out[0], Output::CloseSession(_)), "service and session agent ship together");
    }

    #[test]
    fn forwards_requests_and_maps_replies() {
        let mut r = with_session(&[capability::APPS]);
        let out = r.handle(Input::Host(env(7, 0, Body::ListApps(ListApps {}))));
        let fwd = to_session(&out)[0].clone();
        assert_eq!(fwd.reply_to, 0);
        assert_eq!(fwd.body, Some(Body::ListApps(ListApps {})));
        let out = r.handle(Input::Session(env(5, fwd.seq, Body::AppList(Default::default()))));
        let h = to_host(&out);
        assert_eq!(h[0].reply_to, 7);
        assert_eq!(h[0].body, Some(Body::AppList(Default::default())));
        // A second reply to the same request is dropped.
        assert!(r.handle(Input::Session(env(6, fwd.seq, Body::Ack(Ack {})))).is_empty());
    }

    #[test]
    fn session_exit_fails_pending_requests_and_drops_capabilities() {
        let mut r = with_session(&[capability::APPS]);
        r.handle(Input::Host(env(7, 0, Body::ListApps(ListApps {}))));
        let out = r.handle(Input::SessionClosed);
        let h = to_host(&out);
        assert_eq!(h[0].reply_to, 7);
        assert!(matches!(&h[0].body, Some(Body::Error(e)) if e.code == error::Code::Internal as i32));
        let Some(Body::Hello(hello)) = &h[1].body else { panic!("capabilities changed: fresh Hello") };
        assert_eq!(hello.capabilities, ["core.v1", "system.v1"]);
    }

    #[test]
    fn session_events_and_requests_reach_the_host() {
        let mut r = with_session(&[capability::WINDOWS]);
        let out = r.handle(Input::Session(env(2, 0, Body::WindowSnapshot(WindowSnapshot::default()))));
        assert_eq!(to_host(&out)[0].reply_to, 0);
        let open = Body::OpenOnHost(OpenOnHost::default());
        let out = r.handle(Input::Session(env(3, 0, open)));
        let req = to_host(&out)[0].seq;
        let out = r.handle(Input::Host(env(20, req, Body::Ack(Ack {}))));
        assert_eq!(to_session(&out)[0].reply_to, 3);
        // Spoofing service messages is refused.
        let out = r.handle(Input::Session(env(4, 0, Body::GuestInfo(info()))));
        assert!(to_host(&out).is_empty());
        let out = r.handle(Input::Session(env(5, 0, Body::Hello(session_hello(&[])))));
        assert!(to_host(&out).is_empty());
    }

    #[test]
    fn host_reconnect_is_announced_and_old_mappings_die() {
        let mut r = with_session(&[capability::APPS]);
        let out = r.handle(Input::Host(env(7, 0, Body::ListApps(ListApps {}))));
        let fwd = to_session(&out)[0].seq;
        let out = r.handle(Input::Host(env(1, 0, Body::Hello(host_hello()))));
        assert_eq!(to_host(&out)[0].seq, 1);
        assert!(matches!(to_session(&out)[0].body, Some(Body::Hello(_))));
        // The old request's reply goes nowhere.
        assert!(to_host(&r.handle(Input::Session(env(9, fwd, Body::AppList(Default::default()))))).is_empty());
    }

    #[test]
    fn host_reset_sends_hello_again() {
        let mut r = connected();
        let out = r.handle(Input::HostReset);
        assert!(r.host().is_none());
        assert!(matches!(to_host(&out)[0].body, Some(Body::Hello(_))));
    }

    #[test]
    fn events_without_host_are_dropped_requests_fail() {
        let mut r = router();
        r.start();
        r.handle(Input::SessionConnected);
        r.handle(Input::Session(env(1, 0, Body::Hello(session_hello(&[])))));
        assert!(to_host(&r.handle(Input::Session(env(2, 0, Body::WindowSnapshot(Default::default()))))).is_empty());
        let out = r.handle(Input::Session(env(3, 0, Body::OpenOnHost(OpenOnHost::default()))));
        assert_eq!(to_session(&out)[0].reply_to, 3);
    }
}
