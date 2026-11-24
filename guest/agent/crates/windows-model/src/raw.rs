//! What the Win32 side reports about one top-level window, and the trait it
//! implements. Everything here is plain data, so recorded dumps can stand in
//! for a live Windows session in tests.

use serde::{Deserialize, Serialize};

/// Window styles (`GWL_STYLE`) the classifier reads.
pub mod style {
    pub const POPUP: u32 = 0x8000_0000;
    pub const CHILD: u32 = 0x4000_0000;
    pub const MINIMIZE: u32 = 0x2000_0000;
    pub const VISIBLE: u32 = 0x1000_0000;
    pub const MAXIMIZE: u32 = 0x0100_0000;
    /// `WS_BORDER | WS_DLGFRAME`: both bits set means a title bar.
    pub const CAPTION: u32 = 0x00C0_0000;
    pub const SYSMENU: u32 = 0x0008_0000;
    pub const THICKFRAME: u32 = 0x0004_0000;
    pub const MINIMIZEBOX: u32 = 0x0002_0000;
    pub const MAXIMIZEBOX: u32 = 0x0001_0000;
}

/// Extended window styles (`GWL_EXSTYLE`) the classifier reads.
pub mod ex_style {
    pub const DLGMODALFRAME: u32 = 0x0000_0001;
    pub const TOPMOST: u32 = 0x0000_0008;
    pub const TRANSPARENT: u32 = 0x0000_0020;
    pub const TOOLWINDOW: u32 = 0x0000_0080;
    pub const APPWINDOW: u32 = 0x0004_0000;
    pub const LAYERED: u32 = 0x0008_0000;
    pub const NOREDIRECTIONBITMAP: u32 = 0x0020_0000;
    pub const NOACTIVATE: u32 = 0x0800_0000;
}

/// A rectangle in guest display-1 pixels. `w`/`h` may be negative or zero in
/// raw data (broken apps, minimised windows); the classifier treats that as
/// empty.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Self { x, y, w, h }
    }

    pub fn is_empty(&self) -> bool {
        self.w <= 0 || self.h <= 0
    }

    pub fn intersects(&self, other: &Rect) -> bool {
        if self.is_empty() || other.is_empty() {
            return false;
        }
        let (ax2, ay2) = (self.x as i64 + self.w as i64, self.y as i64 + self.h as i64);
        let (bx2, by2) = (other.x as i64 + other.w as i64, other.y as i64 + other.h as i64);
        (self.x as i64) < bx2 && (other.x as i64) < ax2 && (self.y as i64) < by2 && (other.y as i64) < ay2
    }
}

/// Guest display 1: its full rectangle and the work area (the Mac's
/// `visibleFrame`, pushed with `SPI_SETWORKAREA`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Display {
    pub rect: Rect,
    pub work_area: Rect,
}

/// One top-level window, as the Win32 side reads it. Field sources:
///
/// | Field | Win32 source |
/// |-------|--------------|
/// | `hwnd` | the `HWND` from `EnumWindows` / the WinEvent hook |
/// | `owner` | `GetWindow(hwnd, GW_OWNER)` (0 = none) |
/// | `class` | `GetClassNameW` |
/// | `title` | `GetWindowTextW` (via `InternalGetWindowText`, which never sends a message to a hung app) |
/// | `style`, `ex_style` | `GetWindowLongPtrW(GWL_STYLE / GWL_EXSTYLE)` |
/// | `pid` | `GetWindowThreadProcessId` |
/// | `process` | `QueryFullProcessImageNameW` on that pid (empty if access is denied) |
/// | `aumid` | `SHGetPropertyStoreForWindow` → `PKEY_AppUserModel_ID`; for packaged apps without one, `GetApplicationUserModelId` on the process. For `ApplicationFrameWindow`, the hosted CoreWindow's app |
/// | `cloaked` | `DwmGetWindowAttribute(DWMWA_CLOAKED)`: 1 app, 2 shell (other virtual desktop, suspended UWP), 4 inherited |
/// | `rect` | `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` (without the invisible resize border); `GetWindowRect` if DWM fails |
/// | `restore_rect` | `GetWindowPlacement().rcNormalPosition`, converted to screen coordinates, only for minimised windows |
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawWindow {
    #[serde(with = "hex64")]
    pub hwnd: u64,
    #[serde(with = "hex64", default, skip_serializing_if = "is_zero64")]
    pub owner: u64,
    pub class: String,
    #[serde(default)]
    pub title: String,
    #[serde(with = "hex32")]
    pub style: u32,
    #[serde(with = "hex32", default)]
    pub ex_style: u32,
    pub pid: u32,
    #[serde(default)]
    pub process: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aumid: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero32")]
    pub cloaked: u32,
    pub rect: Rect,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore_rect: Option<Rect>,
}

impl RawWindow {
    pub fn visible(&self) -> bool {
        self.style & style::VISIBLE != 0
    }
    pub fn minimized(&self) -> bool {
        self.style & style::MINIMIZE != 0
    }
    pub fn maximized(&self) -> bool {
        self.style & style::MAXIMIZE != 0
    }
    pub fn has_caption(&self) -> bool {
        self.style & style::CAPTION == style::CAPTION
    }
    pub fn has(&self, s: u32) -> bool {
        self.style & s != 0
    }
    pub fn has_ex(&self, s: u32) -> bool {
        self.ex_style & s != 0
    }
    /// The executable's file name (`notepad.exe`), lowercased.
    pub fn process_name(&self) -> String {
        self.process.rsplit(['\\', '/']).next().unwrap_or("").to_lowercase()
    }
    /// The rectangle the host should see: the restore rectangle while
    /// minimised (DWM reports a parked -32000 rectangle then), else `rect`.
    pub fn effective_rect(&self) -> Rect {
        match (self.minimized(), self.restore_rect) {
            (true, Some(r)) => r,
            _ => self.rect,
        }
    }
}

/// WinEvents the agent hooks (`SetWinEventHook`, out of context). Any of them
/// on a top-level window means "re-read the window list before the next
/// frame"; the tracker diffs whole lists, so events only schedule work.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WinEvent {
    Create,
    Destroy,
    Show,
    Hide,
    LocationChange,
    NameChange,
    Cloaked,
    Uncloaked,
    Foreground,
    MinimizeStart,
    MinimizeEnd,
    MoveSizeStart,
    MoveSizeEnd,
}

impl WinEvent {
    /// The raw `EVENT_*` constant, for registering the hook.
    pub const fn code(self) -> u32 {
        match self {
            WinEvent::Foreground => 0x0003,
            WinEvent::MoveSizeStart => 0x000A,
            WinEvent::MoveSizeEnd => 0x000B,
            WinEvent::MinimizeStart => 0x0016,
            WinEvent::MinimizeEnd => 0x0017,
            WinEvent::Create => 0x8000,
            WinEvent::Destroy => 0x8001,
            WinEvent::Show => 0x8002,
            WinEvent::Hide => 0x8003,
            WinEvent::LocationChange => 0x800B,
            WinEvent::NameChange => 0x800C,
            WinEvent::Cloaked => 0x8017,
            WinEvent::Uncloaked => 0x8018,
        }
    }

    pub fn from_code(code: u32) -> Option<Self> {
        use WinEvent::*;
        [
            Create, Destroy, Show, Hide, LocationChange, NameChange, Cloaked, Uncloaked, Foreground,
            MinimizeStart, MinimizeEnd, MoveSizeStart, MoveSizeEnd,
        ]
        .into_iter()
        .find(|e| e.code() == code)
    }

    /// Whether an event with these hook arguments concerns a top-level window
    /// (`idObject == OBJID_WINDOW`, `idChild == CHILDID_SELF`). Caret,
    /// cursor and child-object events are ignored: they fire constantly.
    pub fn is_window_level(id_object: i32, id_child: i32) -> bool {
        id_object == 0 && id_child == 0
    }
}

/// The Win32 side: implemented in the session agent with `EnumWindows` and
/// the table on [`RawWindow`]; implemented by [`crate::dump::Dump`] in tests.
pub trait WindowSource {
    fn display(&self) -> Display;
    /// Every top-level window, **front to back** (the `EnumWindows` order),
    /// hidden ones included: the classifier decides what to drop.
    fn windows(&mut self) -> Vec<RawWindow>;
}

fn is_zero64(v: &u64) -> bool {
    *v == 0
}
fn is_zero32(v: &u32) -> bool {
    *v == 0
}

/// `"0x…"` strings in dumps, so handles and styles read like Spy++.
macro_rules! hex_mod {
    ($name:ident, $t:ty, $width:literal) => {
        pub(crate) mod $name {
            use serde::{Deserialize, Deserializer, Serializer, de::Error};
            pub fn serialize<S: Serializer>(v: &$t, s: S) -> Result<S::Ok, S::Error> {
                s.serialize_str(&format!(concat!("0x{:0", $width, "X}"), v))
            }
            pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<$t, D::Error> {
                let s = String::deserialize(d)?;
                let digits = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).ok_or_else(|| {
                    D::Error::custom(format!("expected a 0x-prefixed hex string, got {s:?}"))
                })?;
                <$t>::from_str_radix(digits, 16).map_err(D::Error::custom)
            }
        }
    };
}
hex_mod!(hex64, u64, 8);
hex_mod!(hex32, u32, 8);

/// `Option<u64>` as an optional hex string.
pub(crate) mod opt_hex64 {
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(v: &Option<u64>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            Some(v) => super::hex64::serialize(v, s),
            None => s.serialize_none(),
        }
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
        #[derive(Deserialize)]
        struct W(#[serde(with = "super::hex64")] u64);
        Ok(Option::<W>::deserialize(d)?.map(|w| w.0))
    }
}
