//! Agent-assigned window ids and diffs between window lists, emitted as the
//! protocol messages the host's `ZenWindowModel` consumes (docs/06,
//! "Windows (seamless)").
//!
//! The agent calls [`Tracker::snapshot`] after every (re)connect, then
//! [`Tracker::update`] at most once per frame while WinEvents are arriving
//! (they only mark the list dirty; see [`crate::WinEvent`]). Each call takes
//! a whole fresh window list, so missed or reordered events cannot leave the
//! host out of date.
//!
//! - Ids start at 1 and are never reused in a tracker's life. An HWND that
//!   comes back with a different pid or class is a new window (HWNDs are
//!   recycled), so it gets a new id after a `WindowRemoved` for the old one.
//! - `WindowAdded` messages come owners first, so `owner_id` always names a
//!   window the host already knows.
//! - `WindowUpdated` carries the whole window and lists the changed fields.
//! - Titles are cut to [`MAX_TITLE_CHARS`] and at most [`MAX_WINDOWS`]
//!   windows are reported (the front-most), matching the host's caps.

use std::collections::{HashMap, HashSet};

use proto::v1::{
    self, FullscreenState, WindowAdded, WindowField, WindowFlags, WindowRemoved, WindowShowState, WindowSnapshot,
    WindowUpdated, envelope::Body,
};

use crate::classify::{Class, classify};
use crate::raw::{Display, RawWindow, WindowSource};
use crate::rules::Rules;

/// The host's caps (`ZenWindowModel.maxWindows`, `.maxTitleLength`).
pub const MAX_WINDOWS: usize = 512;
pub const MAX_TITLE_CHARS: usize = 256;

#[derive(Clone, Debug)]
struct Known {
    id: u64,
    pid: u32,
    class: String,
    window: v1::Window,
}

#[derive(Debug)]
pub struct Tracker {
    rules: Rules,
    next_id: u64,
    known: HashMap<u64, Known>,
    /// Back-to-front HWNDs from the last list.
    order: Vec<u64>,
    fullscreen: u64,
    icons: HashMap<u64, String>,
}

impl Tracker {
    pub fn new(rules: Rules) -> Self {
        Self { rules, next_id: 1, known: HashMap::new(), order: Vec::new(), fullscreen: 0, icons: HashMap::new() }
    }

    /// Full state, back to front; the new baseline for [`Tracker::update`].
    /// Ids of windows already known are kept.
    pub fn snapshot(&mut self, display: &Display, windows: &[RawWindow]) -> WindowSnapshot {
        self.reconcile(display, windows);
        WindowSnapshot { windows: self.order.iter().map(|h| self.known[h].window.clone()).collect() }
    }

    /// The messages that bring the host from the last list to this one:
    /// removals, then additions (owners first), then updates, then a
    /// `FullscreenState` if the fullscreen window changed (`id` 0 = none).
    pub fn update(&mut self, display: &Display, windows: &[RawWindow]) -> Vec<Body> {
        let before = self.known.clone();
        let before_fullscreen = self.fullscreen;
        self.reconcile(display, windows);

        let mut out = Vec::new();
        let now_ids: HashSet<u64> = self.known.values().map(|k| k.id).collect();
        let mut removed: Vec<u64> = before.values().map(|k| k.id).filter(|id| !now_ids.contains(id)).collect();
        removed.sort_unstable();
        out.extend(removed.into_iter().map(|id| Body::WindowRemoved(WindowRemoved { id })));

        let old_by_id: HashMap<u64, &v1::Window> = before.values().map(|k| (k.id, &k.window)).collect();
        let mut added: Vec<&v1::Window> = Vec::new();
        let mut updated = Vec::new();
        for hwnd in &self.order {
            let w = &self.known[hwnd].window;
            match old_by_id.get(&w.id) {
                None => added.push(w),
                Some(old) => {
                    let changed = changed_fields(old, w);
                    if !changed.is_empty() {
                        updated.push(Body::WindowUpdated(WindowUpdated {
                            window: Some(w.clone()),
                            changed: changed.into_iter().map(|f| f as i32).collect(),
                        }));
                    }
                }
            }
        }
        // Owners first: emit a window once its owner is known to the host.
        let mut host_knows: HashSet<u64> = old_by_id.keys().copied().collect();
        while !added.is_empty() {
            let before_len = added.len();
            added.retain(|w| {
                if w.owner_id == 0 || host_knows.contains(&w.owner_id) {
                    host_knows.insert(w.id);
                    out.push(Body::WindowAdded(WindowAdded { window: Some((*w).clone()) }));
                    false
                } else {
                    true
                }
            });
            if added.len() == before_len {
                // Unreachable by construction (owners are in the same list);
                // send the rest rather than lose them.
                for w in added.drain(..) {
                    out.push(Body::WindowAdded(WindowAdded { window: Some(w.clone()) }));
                }
            }
        }
        out.extend(updated);
        if self.fullscreen != before_fullscreen {
            let id = self.known.get(&self.fullscreen).map_or(0, |k| k.id);
            out.push(Body::FullscreenState(FullscreenState { id, exclusive: false }));
        }
        out
    }

    /// Convenience: read `source` and diff.
    pub fn update_from(&mut self, source: &mut impl WindowSource) -> Vec<Body> {
        let display = source.display();
        let windows = source.windows();
        self.update(&display, &windows)
    }

    /// For host requests (`SetWindowRect`, `WindowCommand`, `PointerFocus`…).
    pub fn hwnd_for_id(&self, id: u64) -> Option<u64> {
        self.known.iter().find(|(_, k)| k.id == id).map(|(h, _)| *h)
    }
    pub fn id_for_hwnd(&self, hwnd: u64) -> Option<u64> {
        self.known.get(&hwnd).map(|k| k.id)
    }
    /// The `app_key` an `icon_id` stands for (for `GetIcon`).
    pub fn app_key_for_icon(&self, icon_id: u64) -> Option<&str> {
        self.icons.get(&icon_id).map(String::as_str)
    }
    /// The id of the window that covers display 1, if any.
    pub fn fullscreen_id(&self) -> Option<u64> {
        self.known.get(&self.fullscreen).map(|k| k.id)
    }

    fn reconcile(&mut self, display: &Display, windows: &[RawWindow]) {
        let classes = classify(windows, display, &self.rules);
        let mut known = HashMap::new();
        let mut order = Vec::new();
        // Front to back, so the cap keeps the front-most windows.
        let mirrored: Vec<(&RawWindow, &crate::Mirrored)> = windows
            .iter()
            .zip(&classes)
            .filter_map(|(w, c)| if let Class::Mirrored(m) = c { Some((w, m)) } else { None })
            .take(MAX_WINDOWS)
            .collect();
        // Ids first (owners may be behind or in front).
        let mut ids: HashMap<u64, u64> = HashMap::new();
        for (w, _) in &mirrored {
            let id = match self.known.get(&w.hwnd) {
                Some(k) if k.pid == w.pid && k.class == w.class => k.id,
                _ => {
                    let id = self.next_id;
                    self.next_id += 1;
                    id
                }
            };
            ids.insert(w.hwnd, id);
        }
        let keys = app_keys(&mirrored);
        for (w, m) in mirrored.iter().rev() {
            let app_key = keys[&w.hwnd].clone();
            let icon_id = icon_id(&app_key);
            if icon_id != 0 {
                self.icons.insert(icon_id, app_key.clone());
            }
            let window = v1::Window {
                id: ids[&w.hwnd],
                owner_id: ids.get(&m.owner).copied().unwrap_or(0),
                kind: m.kind.to_proto() as i32,
                rect: Some(v1::Rect {
                    x: m.rect.x,
                    y: m.rect.y,
                    width: m.rect.w.max(0) as u32,
                    height: m.rect.h.max(0) as u32,
                }),
                title: w.title.chars().take(MAX_TITLE_CHARS).collect(),
                app_key,
                pid: w.pid,
                state: if w.minimized() {
                    WindowShowState::Minimized
                } else if w.maximized() {
                    WindowShowState::Maximized
                } else {
                    WindowShowState::Normal
                } as i32,
                flags: Some(WindowFlags { resizable: m.resizable, topmost: m.topmost, has_alpha: m.has_alpha }),
                icon_id,
            };
            order.push(w.hwnd);
            known.insert(w.hwnd, Known { id: window.id, pid: w.pid, class: w.class.clone(), window });
        }
        // The front-most fullscreen window is the game-mode candidate.
        self.fullscreen = mirrored.iter().find(|(_, m)| m.fullscreen).map_or(0, |(w, _)| w.hwnd);
        self.order = owners_first(order, &known);
        self.known = known;
    }
}

/// Windows keeps owned windows above their owners, but an enumeration that
/// races a z-order change can see otherwise. The host reads the snapshot
/// back to front, so a window listed behind its owner is moved in front of
/// it (order is kept otherwise; an owner cycle from bad data keeps list order).
fn owners_first(order: Vec<u64>, known: &HashMap<u64, Known>) -> Vec<u64> {
    let mut placed_ids: HashSet<u64> = HashSet::new();
    let all_ids: HashSet<u64> = known.values().map(|k| k.id).collect();
    let mut out = Vec::with_capacity(order.len());
    let mut pending = order;
    while !pending.is_empty() {
        let before = pending.len();
        let mut rest = Vec::new();
        for h in pending {
            let w = &known[&h].window;
            if w.owner_id == 0 || !all_ids.contains(&w.owner_id) || placed_ids.contains(&w.owner_id) {
                placed_ids.insert(w.id);
                out.push(h);
            } else {
                rest.push(h);
            }
        }
        if rest.len() == before {
            out.extend(rest);
            break;
        }
        pending = rest;
    }
    out
}

/// docs/05 "App identity": AppUserModelID if set, else the process image
/// path. Lowercased: both are case-insensitive on Windows. This is one
/// window on its own; [`app_keys`] groups a whole list.
pub fn app_key(w: &RawWindow) -> String {
    aumid(w).unwrap_or_else(|| w.process.to_lowercase())
}

fn aumid(w: &RawWindow) -> Option<String> {
    match w.aumid.as_deref().map(str::trim) {
        Some(a) if !a.is_empty() => Some(a.to_lowercase()),
        _ => None,
    }
}

/// `app_key` for every mirrored window, so one app's windows group together
/// on the Mac even though Windows sets the AppUserModelID per window (Office
/// sets it on its main window only, never on dialogs):
///
/// 1. the window's own AUMID;
/// 2. else its mirrored owner's key (a dialog joins the app it belongs to);
/// 3. else the AUMID of its process's other windows, if they agree on one
///    (`ApplicationFrameHost` hosts many apps, so it rarely does);
/// 4. else the process image path.
pub fn app_keys(mirrored: &[(&RawWindow, &crate::Mirrored)]) -> HashMap<u64, String> {
    let mut per_pid: HashMap<u32, Option<String>> = HashMap::new();
    for (w, _) in mirrored {
        if let Some(a) = aumid(w) {
            per_pid
                .entry(w.pid)
                .and_modify(|seen| {
                    if seen.as_ref() != Some(&a) {
                        *seen = None;
                    }
                })
                .or_insert(Some(a));
        }
    }
    let own: HashMap<u64, String> = mirrored
        .iter()
        .map(|(w, _)| {
            let key = aumid(w)
                .or_else(|| per_pid.get(&w.pid).cloned().flatten())
                .unwrap_or_else(|| w.process.to_lowercase());
            (w.hwnd, key)
        })
        .collect();
    let by_hwnd: HashMap<u64, (&RawWindow, &crate::Mirrored)> = mirrored.iter().map(|p| (p.0.hwnd, *p)).collect();
    mirrored
        .iter()
        .map(|(w, m)| {
            if aumid(w).is_some() {
                return (w.hwnd, own[&w.hwnd].clone());
            }
            // Follow mirrored owners to the top-most one that is in the list.
            let mut top = w.hwnd;
            let mut owner = m.owner;
            for _ in 0..crate::classify::MAX_OWNER_DEPTH {
                match by_hwnd.get(&owner) {
                    Some((ow, om)) if owner != top => {
                        top = owner;
                        if aumid(ow).is_some() {
                            break;
                        }
                        owner = om.owner;
                    }
                    _ => break,
                }
            }
            (w.hwnd, own[&top].clone())
        })
        .collect()
}

/// A stable, non-zero id per `app_key` (FNV-1a 64), so the host can cache
/// icons across windows and reconnects. 0 when there is no app key.
pub fn icon_id(app_key: &str) -> u64 {
    if app_key.is_empty() {
        return 0;
    }
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in app_key.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h.max(1)
}

fn changed_fields(a: &v1::Window, b: &v1::Window) -> Vec<WindowField> {
    let mut f = Vec::new();
    if a.owner_id != b.owner_id {
        f.push(WindowField::OwnerId);
    }
    if a.kind != b.kind {
        f.push(WindowField::Kind);
    }
    if a.rect != b.rect {
        f.push(WindowField::Rect);
    }
    if a.title != b.title {
        f.push(WindowField::Title);
    }
    if a.app_key != b.app_key {
        f.push(WindowField::AppKey);
    }
    if a.pid != b.pid {
        f.push(WindowField::Pid);
    }
    if a.state != b.state {
        f.push(WindowField::State);
    }
    if a.flags != b.flags {
        f.push(WindowField::Flags);
    }
    if a.icon_id != b.icon_id {
        f.push(WindowField::IconId);
    }
    f
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::raw::{Rect, style};

    const D: Display = Display { rect: Rect::new(0, 0, 1920, 1080), work_area: Rect::new(0, 0, 1920, 1032) };
    const APP: u32 = style::VISIBLE | style::CAPTION | style::SYSMENU | style::THICKFRAME | style::MINIMIZEBOX;

    fn w(hwnd: u64, owner: u64, title: &str) -> RawWindow {
        RawWindow {
            hwnd,
            owner,
            class: if owner == 0 { "App".into() } else { "#32770".into() },
            title: title.into(),
            style: APP,
            pid: 7,
            process: r"C:\Apps\App.exe".into(),
            rect: Rect::new(10, 10, 300, 200),
            ..Default::default()
        }
    }

    fn kinds(bodies: &[Body]) -> Vec<String> {
        bodies
            .iter()
            .map(|b| match b {
                Body::WindowAdded(a) => format!("add {}", a.window.as_ref().unwrap().id),
                Body::WindowRemoved(r) => format!("remove {}", r.id),
                Body::WindowUpdated(u) => format!("update {} {:?}", u.window.as_ref().unwrap().id, u.changed),
                Body::FullscreenState(f) => format!("fullscreen {}", f.id),
                other => format!("{other:?}"),
            })
            .collect()
    }

    #[test]
    fn snapshot_is_back_to_front_with_owner_ids() {
        let mut t = Tracker::new(Rules::defaults());
        // Front to back: dialog above its owner.
        let s = t.snapshot(&D, &[w(0x20, 0x10, "Open"), w(0x10, 0, "Main")]);
        let titles: Vec<_> = s.windows.iter().map(|w| (w.title.as_str(), w.id, w.owner_id)).collect();
        assert_eq!(titles, [("Main", 2, 0), ("Open", 1, 2)]);
        assert_eq!(s.windows[0].app_key, r"c:\apps\app.exe");
        assert_eq!(s.windows[0].icon_id, icon_id(r"c:\apps\app.exe"));
        assert_eq!(t.app_key_for_icon(s.windows[0].icon_id), Some(r"c:\apps\app.exe"));
    }

    #[test]
    fn snapshot_puts_owned_windows_in_front_of_owners() {
        let mut t = Tracker::new(Rules::defaults());
        // Raced enumeration: the owner is reported in front of its dialog.
        let s = t.snapshot(&D, &[w(0x10, 0, "Main"), w(0x30, 0, "Other"), w(0x20, 0x10, "Open")]);
        let titles: Vec<_> = s.windows.iter().map(|w| w.title.as_str()).collect();
        assert_eq!(titles, ["Other", "Main", "Open"]);
    }

    #[test]
    fn diffs_add_update_remove() {
        let mut t = Tracker::new(Rules::defaults());
        t.snapshot(&D, &[w(0x10, 0, "Main")]);
        assert!(t.update(&D, &[w(0x10, 0, "Main")]).is_empty());

        let mut moved = w(0x10, 0, "Main*");
        moved.rect.x = 50;
        let b = t.update(&D, &[w(0x20, 0x10, "Save"), moved.clone()]);
        assert_eq!(kinds(&b), ["add 2", "update 1 [4, 5]"]);

        let b = t.update(&D, &[moved]);
        assert_eq!(kinds(&b), ["remove 2"]);
    }

    #[test]
    fn owners_are_added_before_owned_windows() {
        let mut t = Tracker::new(Rules::defaults());
        t.snapshot(&D, &[]);
        // The owner is *in front of* its dialog here (unusual, but possible
        // mid-z-order-change), so back-to-front alone would add the dialog first.
        let b = t.update(&D, &[w(0x10, 0, "Main"), w(0x20, 0x10, "Open")]);
        assert_eq!(kinds(&b), ["add 1", "add 2"]);
        let Body::WindowAdded(a) = &b[1] else { panic!() };
        assert_eq!(a.window.as_ref().unwrap().owner_id, 1);
    }

    #[test]
    fn recycled_hwnd_gets_a_new_id() {
        let mut t = Tracker::new(Rules::defaults());
        t.snapshot(&D, &[w(0x10, 0, "Main")]);
        let mut other = w(0x10, 0, "Other");
        other.pid = 8;
        assert_eq!(kinds(&t.update(&D, &[other])), ["remove 1", "add 2"]);
        assert_eq!(t.hwnd_for_id(2), Some(0x10));
        assert_eq!(t.id_for_hwnd(0x10), Some(2));
    }

    #[test]
    fn windows_that_become_hidden_are_removed() {
        let mut t = Tracker::new(Rules::defaults());
        t.snapshot(&D, &[w(0x10, 0, "Main")]);
        let mut hidden = w(0x10, 0, "Main");
        hidden.style &= !style::VISIBLE;
        assert_eq!(kinds(&t.update(&D, &[hidden])), ["remove 1"]);
        // Shown again: a new id (the host has forgotten it).
        assert_eq!(kinds(&t.update(&D, &[w(0x10, 0, "Main")])), ["add 2"]);
    }

    #[test]
    fn fullscreen_changes_are_reported() {
        let mut t = Tracker::new(Rules::defaults());
        t.snapshot(&D, &[]);
        let game = RawWindow {
            hwnd: 0x30,
            class: "UnrealWindow".into(),
            style: style::VISIBLE | style::POPUP,
            pid: 9,
            process: r"C:\Games\Game.exe".into(),
            rect: D.rect,
            ..Default::default()
        };
        assert_eq!(kinds(&t.update(&D, &[game])), ["add 1", "fullscreen 1"]);
        assert_eq!(t.fullscreen_id(), Some(1));
        assert_eq!(kinds(&t.update(&D, &[])), ["remove 1", "fullscreen 0"]);
    }

    #[test]
    fn caps_titles_and_window_count() {
        let mut t = Tracker::new(Rules::defaults());
        let long = "é".repeat(MAX_TITLE_CHARS + 10);
        let many: Vec<_> = (1..=(MAX_WINDOWS as u64 + 5)).map(|h| w(h, 0, &long)).collect();
        let s = t.snapshot(&D, &many);
        assert_eq!(s.windows.len(), MAX_WINDOWS);
        assert_eq!(s.windows[0].title.chars().count(), MAX_TITLE_CHARS);
        // The front-most (first enumerated) windows are the ones kept.
        assert!(t.id_for_hwnd(1).is_some() && t.id_for_hwnd(MAX_WINDOWS as u64 + 1).is_none());
    }
}
