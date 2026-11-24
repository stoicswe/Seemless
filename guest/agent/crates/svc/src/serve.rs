//! The service's event loop: one thread owns the [`Router`]; the host port
//! and the session pipe post to it from their own threads.
//!
//! Platform-independent. Windows supplies the port opener (vioserial) and
//! the pipe acceptor; the Mac tests supply unix sockets.

use std::io;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use proto::frame::Channel;
pub use transport::link::Duplex;
use transport::link::{self, Received, Writer};

use crate::router::{Input, Output, Router};


pub enum Event {
    HostOpened(Writer),
    Host(Received),
    SessionAccepted { id: u64, writer: Writer, close: Box<dyn Fn() + Send> },
    Session { id: u64, received: Received },
    /// Stop the service (SCM stop/shutdown, or a test).
    Stop,
}

/// Opens the host port, keeps it open, reopens it `retry` after it fails.
/// Runs until the event receiver is gone.
pub fn spawn_host_link<O>(tx: Sender<Event>, mut open: O, retry: Duration) -> io::Result<thread::JoinHandle<()>>
where
    O: FnMut() -> io::Result<Duplex> + Send + 'static,
{
    thread::Builder::new().name("host-link".into()).spawn(move || {
        let mut last_error = String::new();
        loop {
            match open() {
                Ok(d) => {
                    last_error.clear();
                    let failed = tx.clone();
                    let Ok(writer) = Writer::spawn("host", d.writer, move |e| {
                        let _ = failed.send(Event::Host(Received::Reset(format!("write failed: {e}"))));
                    }) else {
                        return;
                    };
                    if tx.send(Event::HostOpened(writer)).is_err() {
                        return;
                    }
                    let Ok(reader) = link::spawn_reader("host", d.reader, Channel::Control, tx.clone(), Event::Host) else {
                        return;
                    };
                    let _ = reader.join();
                    (d.close)();
                }
                Err(e) => {
                    let text = e.to_string();
                    if text != last_error {
                        crate::log(&format!("cannot open the host port: {text} (retrying)"));
                        last_error = text;
                    }
                }
            }
            thread::sleep(retry);
            // The loop thread is gone: stop.
            if tx.send(Event::Host(Received::Reset(String::new()))).is_err() {
                return;
            }
        }
    })
}

/// Accepts session connections with `accept` (blocking) and posts them.
pub fn spawn_session_acceptor<A>(tx: Sender<Event>, mut accept: A) -> io::Result<thread::JoinHandle<()>>
where
    A: FnMut() -> io::Result<Duplex> + Send + 'static,
{
    thread::Builder::new().name("session-accept".into()).spawn(move || {
        let mut id = 0u64;
        loop {
            let d = match accept() {
                Ok(d) => d,
                Err(e) => {
                    crate::log(&format!("session pipe: {e}"));
                    thread::sleep(Duration::from_secs(1));
                    continue;
                }
            };
            id += 1;
            let this = id;
            let failed = tx.clone();
            let Ok(writer) = Writer::spawn("session", d.writer, move |e| {
                let _ = failed.send(Event::Session { id: this, received: Received::Closed(format!("write failed: {e}")) });
            }) else {
                continue;
            };
            if tx.send(Event::SessionAccepted { id: this, writer, close: d.close }).is_err() {
                return;
            }
            let posted = tx.clone();
            let spawned = link::spawn_reader("session", d.reader, Channel::Control, tx.clone(), move |received| Event::Session {
                id: this,
                received,
            });
            if spawned.is_err() {
                let _ = posted.send(Event::Session { id: this, received: Received::Closed("no reader thread".into()) });
            }
        }
    })
}

/// The current session connection: id, writer, closer.
type SessionConn = (u64, Writer, Box<dyn Fn() + Send>);

/// Runs the router until [`Event::Stop`].
pub fn run(mut router: Router, rx: Receiver<Event>) {
    let mut host: Option<Writer> = None;
    let mut last_close = String::new();
    let mut session: Option<SessionConn> = None;
    for event in rx {
        let outputs = match event {
            Event::Stop => break,
            Event::HostOpened(w) => {
                host = Some(w);
                router.start()
            }
            Event::Host(Received::Envelope(env)) => {
                last_close.clear();
                router.handle(Input::Host(env))
            }
            Event::Host(Received::Reset(why)) => {
                if why.is_empty() {
                    continue; // the host-link thread checking we are alive
                }
                crate::log(&format!("host link reset: {why}"));
                router.handle(Input::HostReset)
            }
            Event::Host(Received::Closed(why)) => {
                if why != last_close {
                    crate::log(&format!("host port closed: {why} (reopening)"));
                    last_close = why;
                }
                host = None;
                router.handle(Input::HostReset)
            }
            Event::SessionAccepted { id, writer, close } => {
                if let Some((_, _, old)) = session.take() {
                    old();
                }
                session = Some((id, writer, close));
                router.handle(Input::SessionConnected)
            }
            Event::Session { id, received } => {
                if session.as_ref().map(|s| s.0) != Some(id) {
                    continue; // a replaced connection
                }
                match received {
                    Received::Envelope(env) => router.handle(Input::Session(env)),
                    Received::Reset(why) | Received::Closed(why) => {
                        crate::log(&format!("session link closed: {why}"));
                        if let Some((_, _, close)) = session.take() {
                            close();
                        }
                        router.handle(Input::SessionClosed)
                    }
                }
            }
        };
        for out in outputs {
            match out {
                Output::Host(env) => {
                    if let Some(w) = &host {
                        w.send(&env);
                    }
                }
                Output::Session(env) => {
                    if let Some((_, w, _)) = &session {
                        w.send(&env);
                    }
                }
                Output::CloseSession(why) => {
                    crate::log(&format!("closing session link: {why}"));
                    if let Some((_, _, close)) = session.take() {
                        close();
                    }
                    for out in router.handle(Input::SessionClosed) {
                        if let (Output::Host(env), Some(w)) = (out, &host) {
                            w.send(&env);
                        }
                    }
                }
                Output::Log(line) => crate::log(&line),
            }
        }
    }
    if let Some((_, _, close)) = session.take() {
        close();
    }
}

/// A channel for [`run`] and the link threads.
pub fn channel() -> (Sender<Event>, Receiver<Event>) {
    mpsc::channel()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use proto::handshake::{self, capability};
    use proto::v1::envelope::Body;
    use proto::v1::{Envelope, GetGuestInfo, GuestInfo, ListApps, Ping, Role};
    use std::os::unix::net::UnixStream;
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    const T: Duration = Duration::from_secs(5);

    fn duplex(s: UnixStream) -> Duplex {
        let w = s.try_clone().unwrap();
        let c = s.try_clone().unwrap();
        Duplex { reader: Box::new(s), writer: Box::new(w), close: Box::new(move || drop(c.shutdown(std::net::Shutdown::Both))) }
    }

    /// The test's end of a link: framed envelopes over a unix socket.
    struct Peer {
        stream: UnixStream,
        rx: Receiver<Received>,
        seq: u64,
    }

    impl Peer {
        fn new(stream: UnixStream) -> Self {
            let (tx, rx) = mpsc::channel();
            link::spawn_reader("peer", stream.try_clone().unwrap(), Channel::Control, tx, |r| r).unwrap();
            Self { stream, rx, seq: 0 }
        }
        fn send(&mut self, reply_to: u64, body: Body) -> u64 {
            self.seq += 1;
            self.stream.write_all(&Envelope { seq: self.seq, reply_to, body: Some(body) }.to_frame()).unwrap();
            self.seq
        }
        fn recv(&self) -> Envelope {
            match self.rx.recv_timeout(T).expect("a message") {
                Received::Envelope(e) => e,
                other => panic!("{other:?}"),
            }
        }
        /// Next message that is not a Hello.
        fn recv_skipping_hellos(&self) -> Envelope {
            loop {
                let e = self.recv();
                if !matches!(e.body, Some(Body::Hello(_))) {
                    return e;
                }
            }
        }
    }

    fn info() -> GuestInfo {
        GuestInfo { os_build: "test".into(), ..Default::default() }
    }

    #[test]
    fn host_and_session_end_to_end() {
        let (tx, rx) = channel();
        let (host_ours, host_theirs) = UnixStream::pair().unwrap();
        let once = Arc::new(Mutex::new(Some(host_ours)));
        spawn_host_link(
            tx.clone(),
            move || once.lock().unwrap().take().map(duplex).ok_or_else(|| io::Error::other("only one port")),
            Duration::from_millis(50),
        )
        .unwrap();
        let (sess_ours, sess_theirs) = UnixStream::pair().unwrap();
        let pending = Arc::new(Mutex::new(Some(sess_ours)));
        spawn_session_acceptor(tx.clone(), move || {
            if let Some(s) = pending.lock().unwrap().take() {
                return Ok(duplex(s));
            }
            thread::sleep(Duration::from_secs(3600));
            unreachable!()
        })
        .unwrap();
        let loop_thread = thread::spawn(move || run(Router::new("svc test", info), rx));

        // Host: the service's opening Hello, then the handshake.
        let mut host = Peer::new(host_theirs);
        assert!(matches!(host.recv().body, Some(Body::Hello(_))));
        let hello = handshake::hello(Role::Host, "host", &[capability::CORE, capability::APPS]);
        let hs = host.send(0, Body::Hello(hello.clone()));
        assert_eq!(host.recv().reply_to, hs);
        let req = host.send(0, Body::GetGuestInfo(GetGuestInfo {}));
        let reply = host.recv_skipping_hellos();
        assert_eq!((reply.reply_to, reply.body), (req, Some(Body::GuestInfo(info()))));

        // Session agent connects and claims apps.v1.
        let mut sess = Peer::new(sess_theirs);
        let sh = sess.send(0, Body::Hello(handshake::hello(Role::GuestService, "session", &[capability::APPS])));
        assert_eq!(sess.recv().reply_to, sh);
        assert_eq!(sess.recv().body, Some(Body::Hello(hello)), "the host's Hello is forwarded");
        let Some(Body::Hello(again)) = host.recv().body else { panic!("fresh Hello to the host") };
        assert_eq!(again.capabilities, ["apps.v1", "core.v1"]);

        // A host request travels to the session agent and back.
        let req = host.send(0, Body::ListApps(ListApps {}));
        let fwd = sess.recv();
        assert_eq!(fwd.body, Some(Body::ListApps(ListApps {})));
        sess.send(fwd.seq, Body::AppList(Default::default()));
        let back = host.recv();
        assert_eq!((back.reply_to, back.body), (req, Some(Body::AppList(Default::default()))));

        // Session agent goes away: capabilities drop back to core.
        sess.stream.shutdown(std::net::Shutdown::Both).unwrap();
        let Some(Body::Hello(after)) = host.recv().body else { panic!() };
        assert_eq!(after.capabilities, ["core.v1"]);
        let p = host.send(0, Body::Ping(Ping { nonce: 5 }));
        assert_eq!(host.recv().reply_to, p);

        tx.send(Event::Stop).unwrap();
        loop_thread.join().unwrap();
    }
}
