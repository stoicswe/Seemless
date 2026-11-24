//! Recorded window dumps: the test data for the classifier, the format the
//! agent writes when asked to capture the live window list, and the source
//! of mock-agent scripts. The format is described in `tests/data/README.md`.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::classify::{Class, classify};
use crate::raw::{Display, RawWindow, WindowSource, opt_hex64};
use crate::rules::Rules;
use crate::tracker::Tracker;

pub const FORMAT: &str = "seemless-window-dump/1";
/// Bounds for a dump read from disk or from a guest.
pub const MAX_DUMP_WINDOWS: usize = 4096;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// Written by hand from how the app is known to build its windows.
    Synthetic,
    /// Read from a real guest by [`Dump::capture`].
    Captured,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Dump {
    pub format: String,
    pub origin: Origin,
    /// What the dump shows, e.g. "Notepad, two windows, one minimised".
    pub app: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub windows_build: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub captured_at: Option<String>,
    pub display: Display,
    /// Front to back, as `EnumWindows` returns them.
    pub windows: Vec<DumpWindow>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DumpWindow {
    #[serde(flatten)]
    pub raw: RawWindow,
    /// Expected class label: `normal`, `dialog`, `menu`, `tooltip`,
    /// `popup`, `splash`, `tool`, or `ignore:<hidden|cloaked|empty|offscreen|rule>`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expect: Option<String>,
    /// Expected mirrored owner HWND (absent = no owner).
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_hex64")]
    pub expect_owner: Option<u64>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub expect_fullscreen: bool,
    /// Free text: what this window is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct DumpError(pub String);

impl std::fmt::Display for DumpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "window dump: {}", self.0)
    }
}
impl std::error::Error for DumpError {}

impl Dump {
    pub fn from_json(text: &str) -> Result<Self, DumpError> {
        let d: Dump = serde_json::from_str(text).map_err(|e| DumpError(e.to_string()))?;
        if d.format != FORMAT {
            return Err(DumpError(format!("format {:?}, expected {FORMAT:?}", d.format)));
        }
        if d.windows.len() > MAX_DUMP_WINDOWS {
            return Err(DumpError(format!("{} windows, at most {MAX_DUMP_WINDOWS}", d.windows.len())));
        }
        let mut seen = std::collections::HashSet::new();
        for w in &d.windows {
            if w.raw.hwnd == 0 || !seen.insert(w.raw.hwnd) {
                return Err(DumpError(format!("hwnd 0x{:X} is zero or repeated", w.raw.hwnd)));
            }
        }
        Ok(d)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).expect("a dump always serialises") + "\n"
    }

    /// The agent's capture path: the live list as a dump, with no
    /// expectations. Write it with [`Dump::to_json`]; to turn it into a test,
    /// call [`Dump::fill_expectations`] and review every line by hand.
    pub fn capture(source: &mut impl WindowSource, app: &str, windows_build: Option<String>) -> Self {
        let display = source.display();
        let windows = source
            .windows()
            .into_iter()
            .take(MAX_DUMP_WINDOWS)
            .map(|raw| DumpWindow { raw, expect: None, expect_owner: None, expect_fullscreen: false, note: None })
            .collect();
        Dump {
            format: FORMAT.into(),
            origin: Origin::Captured,
            app: app.into(),
            note: None,
            windows_build,
            captured_at: None,
            display,
            windows,
        }
    }

    pub fn raw_windows(&self) -> Vec<RawWindow> {
        self.windows.iter().map(|w| w.raw.clone()).collect()
    }

    pub fn classify(&self, rules: &Rules) -> Vec<Class> {
        classify(&self.raw_windows(), &self.display, rules)
    }

    /// Writes today's classification as the expectations.
    pub fn fill_expectations(&mut self, rules: &Rules) {
        let classes = self.classify(rules);
        for (w, c) in self.windows.iter_mut().zip(classes) {
            w.expect = Some(c.label());
            let m = c.mirrored();
            w.expect_owner = m.map(|m| m.owner).filter(|o| *o != 0);
            w.expect_fullscreen = m.is_some_and(|m| m.fullscreen);
        }
    }

    /// Every way the classification differs from the expectations; a window
    /// with no `expect` is itself a mismatch.
    pub fn mismatches(&self, rules: &Rules) -> Vec<String> {
        let mut out = Vec::new();
        for (w, c) in self.windows.iter().zip(self.classify(rules)) {
            let who = format!("0x{:08X} {} {:?}", w.raw.hwnd, w.raw.class, w.raw.title);
            let Some(expect) = &w.expect else {
                out.push(format!("{who}: no expectation (got {})", c.label()));
                continue;
            };
            if *expect != c.label() {
                let why = match &c {
                    Class::Ignored(crate::Ignored::Rule(r)) => format!(" (rule {r:?})"),
                    Class::Mirrored(m) => m.rule.as_ref().map(|r| format!(" (rule {r:?})")).unwrap_or_default(),
                    _ => String::new(),
                };
                out.push(format!("{who}: expected {expect}, got {}{why}", c.label()));
            }
            let owner = c.mirrored().map(|m| m.owner).filter(|o| *o != 0);
            if owner != w.expect_owner {
                out.push(format!("{who}: expected owner {:X?}, got {owner:X?}", w.expect_owner));
            }
            let fullscreen = c.mirrored().is_some_and(|m| m.fullscreen);
            if fullscreen != w.expect_fullscreen {
                out.push(format!("{who}: expected fullscreen {}, got {fullscreen}", w.expect_fullscreen));
            }
        }
        out
    }

    /// A `seemlessctl mock-agent` script (proto/mock/) that announces this
    /// dump's classified windows as one `WindowSnapshot`, exactly as the
    /// agent would send them.
    pub fn mock_script(&self, rules: &Rules) -> Value {
        let mut tracker = Tracker::new(rules.clone());
        let snapshot = tracker.snapshot(&self.display, &self.raw_windows());
        let windows: Vec<Value> = snapshot.windows.iter().map(window_json).collect();
        json!({
            "build": format!("seemless-mock-agent dump: {}", self.app),
            "capabilities": ["core.v1", "system.v1", "windows.v1"],
            "steps": [
                {"send": {"sessionState": {"loggedOn": true, "user": "Seemless"}}},
                {"send": {"windowSnapshot": {"windows": windows}}}
            ]
        })
    }
}

impl WindowSource for Dump {
    fn display(&self) -> Display {
        self.display
    }
    fn windows(&mut self) -> Vec<RawWindow> {
        self.raw_windows()
    }
}

/// Protobuf JSON for one `Window` (64-bit ints as strings, enum names,
/// camelCase, defaults left out), as `MockAgent` reads it.
fn window_json(w: &proto::v1::Window) -> Value {
    let mut o = serde_json::Map::new();
    o.insert("id".into(), json!(w.id.to_string()));
    if w.owner_id != 0 {
        o.insert("ownerId".into(), json!(w.owner_id.to_string()));
    }
    o.insert("kind".into(), json!(w.kind().as_str_name()));
    if let Some(r) = &w.rect {
        o.insert("rect".into(), json!({"x": r.x, "y": r.y, "width": r.width, "height": r.height}));
    }
    if !w.title.is_empty() {
        o.insert("title".into(), json!(w.title));
    }
    o.insert("appKey".into(), json!(w.app_key));
    o.insert("pid".into(), json!(w.pid));
    o.insert("state".into(), json!(w.state().as_str_name()));
    if let Some(f) = &w.flags {
        let mut flags = serde_json::Map::new();
        for (k, v) in [("resizable", f.resizable), ("topmost", f.topmost), ("hasAlpha", f.has_alpha)] {
            if v {
                flags.insert(k.into(), json!(true));
            }
        }
        o.insert("flags".into(), Value::Object(flags));
    }
    if w.icon_id != 0 {
        o.insert("iconId".into(), json!(w.icon_id.to_string()));
    }
    Value::Object(o)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::raw::{Rect, style};

    fn dump() -> Dump {
        Dump {
            format: FORMAT.into(),
            origin: Origin::Synthetic,
            app: "test".into(),
            note: None,
            windows_build: None,
            captured_at: None,
            display: Display { rect: Rect::new(0, 0, 800, 600), work_area: Rect::new(0, 0, 800, 560) },
            windows: vec![DumpWindow {
                raw: RawWindow {
                    hwnd: 0x1234,
                    class: "App".into(),
                    title: "Main".into(),
                    style: style::VISIBLE | style::CAPTION | style::THICKFRAME,
                    pid: 5,
                    process: r"C:\App.exe".into(),
                    rect: Rect::new(1, 2, 300, 200),
                    ..Default::default()
                },
                expect: Some("normal".into()),
                expect_owner: None,
                expect_fullscreen: false,
                note: None,
            }],
        }
    }

    #[test]
    fn json_round_trip_uses_hex() {
        let d = dump();
        let text = d.to_json();
        assert!(text.contains("\"hwnd\": \"0x00001234\""), "{text}");
        assert!(text.contains("\"style\": \"0x10C40000\""), "{text}");
        assert_eq!(Dump::from_json(&text).unwrap(), d);
    }

    #[test]
    fn rejects_bad_dumps() {
        let mut d = dump();
        d.windows.push(d.windows[0].clone());
        assert!(Dump::from_json(&d.to_json()).unwrap_err().0.contains("repeated"));
        let text = dump().to_json().replace(FORMAT, "other/1");
        assert!(Dump::from_json(&text).unwrap_err().0.contains("format"));
        assert!(Dump::from_json(&dump().to_json().replace("0x00001234", "1234")).is_err());
    }

    #[test]
    fn capture_then_fill_expectations() {
        let mut source = dump();
        let mut d = Dump::capture(&mut source, "captured test", Some("26300".into()));
        assert_eq!(d.origin, Origin::Captured);
        assert_eq!(d.mismatches(&Rules::defaults()).len(), 1, "no expectation yet");
        d.fill_expectations(&Rules::defaults());
        assert!(d.mismatches(&Rules::defaults()).is_empty());
    }

    #[test]
    fn mock_script_shape() {
        let s = dump().mock_script(&Rules::defaults());
        let w = &s["steps"][1]["send"]["windowSnapshot"]["windows"][0];
        assert_eq!(w["id"], "1");
        assert_eq!(w["kind"], "WINDOW_KIND_NORMAL");
        assert_eq!(w["state"], "WINDOW_SHOW_STATE_NORMAL");
        assert_eq!(w["rect"]["width"], 300);
        assert_eq!(w["flags"]["resizable"], true);
        assert!(w.get("ownerId").is_none());
    }
}
