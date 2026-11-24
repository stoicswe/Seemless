//! Window enumeration results, classification and rules.toml (docs/05,
//! docs/06). Pure logic: unit-tested on macOS with recorded window dumps.
//!
//! - [`raw`]: what the Win32 side reads per window ([`RawWindow`]), the
//!   [`WindowSource`] trait it implements, and the WinEvents it hooks.
//! - [`rules`]: `rules.toml` per-app and per-class overrides.
//! - [`classify`]: the classification itself (app window, dialog, menu,
//!   tooltip, popup, splash, tool, or ignored and why).
//! - [`tracker`]: agent-assigned ids and diffs, emitted as the protocol's
//!   `WindowSnapshot/Added/Updated/Removed` and `FullscreenState`, ready to
//!   send.
//! - [`dump`]: the recorded-dump format, capture from any [`WindowSource`],
//!   and mock-agent scripts made from a dump.

pub mod classify;
pub mod dump;
pub mod raw;
pub mod rules;
pub mod tracker;

pub use classify::{Class, Ignored, Mirrored, classify};
pub use dump::Dump;
pub use raw::{Display, RawWindow, Rect, WinEvent, WindowSource};
pub use rules::Rules;
pub use tracker::Tracker;

use proto::v1::WindowKind;

/// The kind of a mirrored window; maps 1:1 onto `seemless.v1.WindowKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Normal,
    Dialog,
    Menu,
    Tooltip,
    Popup,
    Splash,
    Tool,
}

impl Kind {
    pub const ALL: [Kind; 7] =
        [Kind::Normal, Kind::Dialog, Kind::Menu, Kind::Tooltip, Kind::Popup, Kind::Splash, Kind::Tool];

    pub fn name(self) -> &'static str {
        match self {
            Kind::Normal => "normal",
            Kind::Dialog => "dialog",
            Kind::Menu => "menu",
            Kind::Tooltip => "tooltip",
            Kind::Popup => "popup",
            Kind::Splash => "splash",
            Kind::Tool => "tool",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.name() == name)
    }

    pub fn to_proto(self) -> WindowKind {
        match self {
            Kind::Normal => WindowKind::Normal,
            Kind::Dialog => WindowKind::Dialog,
            Kind::Menu => WindowKind::Menu,
            Kind::Tooltip => WindowKind::Tooltip,
            Kind::Popup => WindowKind::Popup,
            Kind::Splash => WindowKind::Splash,
            Kind::Tool => WindowKind::Tool,
        }
    }
}
