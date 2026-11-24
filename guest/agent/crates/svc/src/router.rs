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
use proto::v1::{error, Envelope, Error as ProtoError, GuestInfo, Hello, Pong, Role};

/// Requests in flight across the service, per direction.
pub const MAX_PENDING: usize = 1024;

/// Where `GuestInfo` comes from (the registry on Windows, a fixture in tests).
pub trait GuestInfoSource {
    fn guest_info(&self) -> GuestInfo;
}

impl<F: Fn() -> GuestInfo> GuestInfoSource for F {
    fn guest_info(&self) -> GuestInfo {
        self()
    }
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
    info: Box<dyn GuestInfoSource + Send>,
    host_seq: u64,
    /// The host's Hello on the current connection, once received.
    host_hello: Option<Hello>,
    host_negotiated: Option<Negotiated>,
    /// Capabilities in the last Hello we sent the host.
    advertised: Vec<String>,
    session: SessionLink,
    session_seq: u64,
    /// pipe seq of a forwarded host request → host seq.
    to_session: HashMap<u64, u64>,
    /// host seq of a forwarded session request → pipe seq.
    to_host: HashMap<u64, u64>,
}

impl Router {
    pub fn new(build: impl Into<String>, info: impl GuestInfoSource + Send + 'static) -> Self {
        Self {
            build: build.into(),
            info: Box::new(info),
            host_seq: 0,
            host_hello: None,
            host_negotiated: None,
            advertised: vec![capability::CORE.to_owned()],
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
                let info = self.info.guest_info();
                self.reply_host(out, env.seq, Body::GuestInfo(info));
            }
            // System family (WP4.3/WP4.4) and diagnostics: not built yet.
            Body::SetHostInfo(_) => self.reply_host(out, env.seq, Self::unsupported("SetHostInfo")),
            Body::TimeSync(_) => self.reply_host(out, env.seq, Self::unsupported("TimeSync")),
            Body::Shutdown(_) => self.reply_host(out, env.seq, Self::unsupported("Shutdown")),
            Body::UpdateTools(_) => self.reply_host(out, env.seq, Self::unsupported("UpdateTools")),
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
            self.set_advertised(vec![capability::CORE.to_owned()], out);
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
                        let mut all = vec![capability::CORE.to_owned()];
                        all.extend(caps);
                        self.set_advertised(all, out);
                        self.announce_host_to_session(out);
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
    use proto::v1::{Ack, GetGuestInfo, ListApps, OpenOnHost, Ping, WindowSnapshot};

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
        assert_eq!(ours.capabilities, ["core.v1"]);
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
    fn system_requests_are_unsupported_for_now() {
        let mut r = connected();
        let out = r.handle(Input::Host(env(5, 0, Body::TimeSync(Default::default()))));
        let Some(Body::Error(e)) = &to_host(&out)[0].body else { panic!() };
        assert_eq!(e.code, error::Code::Unsupported as i32);
        assert_eq!(to_host(&out)[0].reply_to, 5);
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
        assert_eq!(again.capabilities, ["core.v1", "windows.v1"]);
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
        assert_eq!(hello.capabilities, ["core.v1"]);
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
