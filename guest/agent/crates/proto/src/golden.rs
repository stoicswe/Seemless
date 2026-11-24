//! Golden frames shared with Swift (`kit/Tests/SeemlessKitTests/AgentProtocolTests.swift`).
//!
//! Each `proto/testdata/<name>.frame` holds one complete control frame. Rust
//! and Swift both build the same envelopes and must produce these exact
//! bytes, and both decode them back. Regenerate after a deliberate change
//! with `SEEMLESS_BLESS=1 cargo test -p proto` and review the diff.

use std::path::PathBuf;

use crate::Message;
use crate::frame::{Channel, Decoder, Kind};
use crate::handshake::{capability, hello};
use crate::v1::envelope::Body;
use crate::v1::*;

pub(crate) fn cases() -> Vec<(&'static str, Envelope)> {
    vec![
        (
            "hello-host",
            Envelope::new(1, Body::Hello(hello(Role::Host, "seemless-host test", &[capability::CORE, capability::WINDOWS]))),
        ),
        ("hello-guest", Envelope::new(1, Body::Hello(hello(Role::GuestService, "seemless-agent test", &[capability::CORE])))),
        ("ping", Envelope::new(2, Body::Ping(Ping { nonce: 0x1122_3344_5566_7788 }))),
        ("pong", Envelope::reply(2, 2, Body::Pong(Pong { nonce: 0x1122_3344_5566_7788 }))),
        (
            "guest-info",
            Envelope::reply(
                3,
                5,
                Body::GuestInfo(GuestInfo {
                    os_build: "10.0.26300.9457".into(),
                    driver_versions: vec![
                        DriverVersion { name: "viogpu3d".into(), version: "0.1".into() },
                        DriverVersion { name: "vioserial".into(), version: "100.95".into() },
                    ],
                    agent_version: "0.0.1".into(),
                    gpu_adapter: "Virtio GPU 3D — Neptune".into(),
                }),
            ),
        ),
        (
            "window-snapshot",
            Envelope::new(
                4,
                Body::WindowSnapshot(WindowSnapshot {
                    windows: vec![
                        Window {
                            id: 1,
                            owner_id: 0,
                            kind: WindowKind::Normal as i32,
                            rect: Some(Rect { x: -8, y: 0, width: 1936, height: 1048 }),
                            title: "Notepad — Ünïcode".into(),
                            app_key: "notepad".into(),
                            pid: 4242,
                            state: WindowShowState::Maximized as i32,
                            flags: Some(WindowFlags { resizable: true, topmost: false, has_alpha: false }),
                            icon_id: 77,
                        },
                        Window {
                            id: 2,
                            owner_id: 1,
                            kind: WindowKind::Dialog as i32,
                            rect: Some(Rect { x: 400, y: 300, width: 480, height: 200 }),
                            title: "Save As".into(),
                            app_key: "notepad".into(),
                            pid: 4242,
                            state: WindowShowState::Normal as i32,
                            flags: Some(WindowFlags { resizable: false, topmost: true, has_alpha: true }),
                            icon_id: 0,
                        },
                    ],
                }),
            ),
        ),
        (
            "error",
            Envelope::reply(
                5,
                9,
                Body::Error(Error { code: error::Code::Unsupported as i32, message: "no such request".into() }),
            ),
        ),
    ]
}

fn testdata() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../proto/testdata"))
}

#[test]
fn golden_frames_match_and_decode() {
    let bless = std::env::var_os("SEEMLESS_BLESS").is_some();
    if bless {
        std::fs::create_dir_all(testdata()).unwrap();
    }
    for (name, envelope) in cases() {
        let path = testdata().join(format!("{name}.frame"));
        let bytes = envelope.to_frame();
        if bless {
            std::fs::write(&path, &bytes).unwrap();
        }
        let golden = std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e} (bless with SEEMLESS_BLESS=1)", path.display()));
        assert_eq!(bytes, golden, "{name}: encoding differs from {}", path.display());

        let mut decoder = Decoder::new(Channel::Control);
        let frames = decoder.push(&golden).unwrap();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].kind, Kind::Envelope);
        assert_eq!(Envelope::decode(frames[0].payload.as_slice()).unwrap(), envelope, "{name}");
    }
}
