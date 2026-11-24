//! The per-user session agent (docs/06 "Agent processes").
//!
//! WP4.2 skeleton: it connects to the service's pipe, does the Hello
//! exchange (the service plays the host role on the pipe) and answers every
//! forwarded request with `Error UNSUPPORTED`. Window tracking (WP5.x),
//! clipboard (WP4.5) and the rest plug in here as they are built.
//!
//! [`Core`] is sans-IO and tested on the Mac.

use proto::handshake::{self, Negotiated};
use proto::v1::envelope::Body;
use proto::v1::{error, Envelope, Error as ProtoError, Hello, Role};

/// Capabilities this build of the session agent implements. Empty until
/// the first family (windows.v1) lands.
pub const CAPABILITIES: &[&str] = &[];

#[derive(Debug, PartialEq)]
pub enum Action {
    Send(Envelope),
    /// The service rejected us or broke protocol: reconnect later.
    Disconnect(String),
    Log(String),
}

pub struct Core {
    build: String,
    seq: u64,
    service: Option<Negotiated>,
    /// The host's Hello as forwarded by the service, if a host is connected.
    pub host: Option<Hello>,
}

impl Core {
    pub fn new(build: impl Into<String>) -> Self {
        Self { build: build.into(), seq: 0, service: None, host: None }
    }

    fn hello(&self) -> Hello {
        handshake::hello(Role::GuestService, &self.build, CAPABILITIES)
    }

    fn envelope(&mut self, reply_to: u64, body: Body) -> Envelope {
        self.seq += 1;
        Envelope { seq: self.seq, reply_to, body: Some(body) }
    }

    pub fn ready(&self) -> bool {
        self.service.is_some()
    }

    /// The first message on a new pipe connection.
    pub fn connected(&mut self) -> Vec<Action> {
        self.seq = 0;
        self.service = None;
        self.host = None;
        let hello = self.hello();
        vec![Action::Send(self.envelope(0, Body::Hello(hello)))]
    }

    pub fn handle(&mut self, env: Envelope) -> Vec<Action> {
        let Some(body) = env.body else { return Vec::new() };
        if self.service.is_none() {
            return match body {
                Body::Hello(h) if env.reply_to != 0 => {
                    match handshake::negotiate(&handshake::hello(Role::GuestService, &self.build, CAPABILITIES), &h) {
                        Ok(n) => {
                            let line = format!("service {} ready", n.peer_build);
                            self.service = Some(n);
                            vec![Action::Log(line)]
                        }
                        Err(e) => vec![Action::Disconnect(format!("service Hello rejected: {e}"))],
                    }
                }
                _ => vec![Action::Disconnect("service did not answer Hello first".into())],
            };
        }
        match body {
            // The host's Hello, forwarded: a host (re)connected. Real state
            // (WindowSnapshot) is sent from here once windows.v1 exists.
            Body::Hello(h) if env.reply_to == 0 => {
                let line = format!("host {} connected", h.build.chars().take(80).collect::<String>());
                self.host = Some(h);
                vec![Action::Log(line)]
            }
            _ if env.reply_to != 0 => Vec::new(),
            _ => {
                let e = ProtoError { code: error::Code::Unsupported as i32, message: "not implemented by the session agent yet".into() };
                vec![Action::Send(self.envelope(env.seq, Body::Error(e)))]
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proto::v1::ListApps;

    fn service_hello() -> Hello {
        handshake::hello(Role::Host, "svc", &["windows.v1"])
    }

    #[test]
    fn hello_then_unsupported() {
        let mut c = Core::new("session test");
        let Action::Send(first) = &c.connected()[0] else { panic!() };
        assert_eq!((first.seq, first.reply_to), (1, 0));
        assert!(matches!(&first.body, Some(Body::Hello(h)) if h.role == Role::GuestService as i32));
        c.handle(Envelope { seq: 1, reply_to: 1, body: Some(Body::Hello(service_hello())) });
        assert!(c.ready());
        let host = handshake::hello(Role::Host, "host", &[]);
        c.handle(Envelope { seq: 2, reply_to: 0, body: Some(Body::Hello(host.clone())) });
        assert_eq!(c.host, Some(host));
        let out = c.handle(Envelope { seq: 3, reply_to: 0, body: Some(Body::ListApps(ListApps {})) });
        let Action::Send(reply) = &out[0] else { panic!() };
        assert_eq!(reply.reply_to, 3);
        assert!(matches!(&reply.body, Some(Body::Error(e)) if e.code == error::Code::Unsupported as i32));
    }

    #[test]
    fn disconnects_on_a_bad_service() {
        let mut c = Core::new("s");
        c.connected();
        let out = c.handle(Envelope { seq: 1, reply_to: 0, body: Some(Body::Ack(Default::default())) });
        assert!(matches!(out[0], Action::Disconnect(_)));
        c.connected();
        let wrong = handshake::hello(Role::GuestService, "svc", &[]);
        let out = c.handle(Envelope { seq: 1, reply_to: 1, body: Some(Body::Hello(wrong)) });
        assert!(matches!(out[0], Action::Disconnect(_)));
    }
}
