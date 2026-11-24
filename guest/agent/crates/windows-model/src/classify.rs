//! Classification (docs/05, "Which windows are mirrored"). Pure function of
//! one window list, front to back, plus the display and the rules.
//!
//! Order of checks for each window:
//!
//! 1. Not visible (`WS_VISIBLE` clear) → ignored, `hidden`.
//! 2. Cloaked (`DWMWA_CLOAKED` ≠ 0: suspended UWP frames, other virtual
//!    desktops, apps that cloak while starting) → ignored, `cloaked`.
//! 3. Not minimised and no area → `empty`; not minimised and wholly off
//!    display 1 → `offscreen` (parked windows, off-screen tricks).
//! 4. The first matching `rules.toml` rule (shell, our own windows,
//!    transient classes, per-app fixes).
//! 5. Style rules:
//!    - `WS_EX_NOACTIVATE` without `WS_EX_APPWINDOW` → `popup`.
//!    - Unowned `WS_POPUP` with no caption, frame, system menu, minimise box
//!      or `WS_EX_APPWINDOW` ("frameless"):
//!      - covering display 1 exactly → `normal` + fullscreen (game mode);
//!      - else the only candidate window of its process → `splash` (it has
//!        no main window yet; tool-window splashes included);
//!      - else → `popup` (custom menus, e.g. Steam's).
//!    - `WS_EX_TOOLWINDOW`: with a caption → `tool` (floating palette), else
//!      `popup`.
//!    - Owned, no `WS_EX_APPWINDOW`: caption or `#32770` → `dialog`, else
//!      `popup`.
//!    - Unowned `#32770` → `dialog` with no owner (a message box from a
//!      console app).
//!    - Anything else → `normal` (app window; custom-chrome apps keep
//!      `WS_THICKFRAME` or a minimise box, so they land here).
//! 6. Owners: a mirrored window's `owner_id` is its nearest mirrored
//!    ancestor on the `GW_OWNER` chain. A `dialog` with no mirrored ancestor
//!    becomes `normal` unless it is `#32770`: that is a main window owned by
//!    a hidden application window (Delphi, VB6, some WinForms apps).

use std::collections::HashMap;

use crate::Kind;
use crate::raw::{Display, RawWindow, Rect, ex_style, style};
use crate::rules::{Effect, Rules};

/// Longest owner chain followed. Windows forbids cycles, but the data comes
/// from a racing enumeration, so it is bounded anyway.
pub(crate) const MAX_OWNER_DEPTH: usize = 32;

/// Why a window is not mirrored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ignored {
    Hidden,
    Cloaked,
    Empty,
    Offscreen,
    /// A `rules.toml` rule with `ignore = true`; holds the rule's name.
    Rule(String),
}

impl Ignored {
    pub fn name(&self) -> &'static str {
        match self {
            Ignored::Hidden => "hidden",
            Ignored::Cloaked => "cloaked",
            Ignored::Empty => "empty",
            Ignored::Offscreen => "offscreen",
            Ignored::Rule(_) => "rule",
        }
    }
}

/// A window the host mirrors.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mirrored {
    pub kind: Kind,
    /// HWND of the nearest mirrored owner, 0 for none.
    pub owner: u64,
    pub rect: Rect,
    pub resizable: bool,
    pub topmost: bool,
    pub has_alpha: bool,
    /// Covers display 1 with no frame: the game-mode trigger (docs/08).
    pub fullscreen: bool,
    /// The rule that decided the kind, for diagnostics.
    pub rule: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Class {
    Mirrored(Mirrored),
    Ignored(Ignored),
}

impl Class {
    pub fn mirrored(&self) -> Option<&Mirrored> {
        match self {
            Class::Mirrored(m) => Some(m),
            Class::Ignored(_) => None,
        }
    }

    /// `normal`, `dialog`, … or `ignore:hidden`, … (the dump `expect` syntax).
    pub fn label(&self) -> String {
        match self {
            Class::Mirrored(m) => m.kind.name().to_string(),
            Class::Ignored(i) => format!("ignore:{}", i.name()),
        }
    }
}

const DIALOG_CLASS: &str = "#32770";

/// Classifies every window; the result is index-aligned with `windows`.
pub fn classify(windows: &[RawWindow], display: &Display, rules: &Rules) -> Vec<Class> {
    // Pass 1: each window on its own.
    let mut out: Vec<Class> = windows.iter().map(|w| classify_one(w, display, rules)).collect();

    // Splash needs the other windows: a frameless unowned popup is a splash
    // only while its process has no other candidate window.
    let mut per_pid: HashMap<u32, usize> = HashMap::new();
    for (w, c) in windows.iter().zip(&out) {
        if let Class::Mirrored(m) = c
            && matches!(m.kind, Kind::Normal | Kind::Dialog | Kind::Splash)
        {
            *per_pid.entry(w.pid).or_default() += 1;
        }
    }
    for (w, c) in windows.iter().zip(out.iter_mut()) {
        if let Class::Mirrored(m) = c
            && m.kind == Kind::Splash
            && m.rule.is_none()
            && per_pid.get(&w.pid).copied().unwrap_or(0) > 1
        {
            m.kind = Kind::Popup;
        }
    }

    // Pass 2: owners.
    let index: HashMap<u64, usize> = windows.iter().enumerate().map(|(i, w)| (w.hwnd, i)).collect();
    let mirrored: Vec<bool> = out.iter().map(|c| c.mirrored().is_some()).collect();
    for (i, w) in windows.iter().enumerate() {
        let Class::Mirrored(m) = &mut out[i] else { continue };
        let mut owner = w.owner;
        let mut found = 0;
        for _ in 0..MAX_OWNER_DEPTH {
            if owner == 0 || owner == w.hwnd {
                break;
            }
            match index.get(&owner) {
                Some(&j) if mirrored[j] => {
                    found = owner;
                    break;
                }
                Some(&j) => owner = windows[j].owner,
                None => break,
            }
        }
        m.owner = found;
        if found == 0 && m.kind == Kind::Dialog && m.rule.is_none() && w.owner != 0 && !is_dialog_class(w) {
            m.kind = Kind::Normal;
        }
    }
    out
}

fn is_dialog_class(w: &RawWindow) -> bool {
    w.class == DIALOG_CLASS
}

fn classify_one(w: &RawWindow, display: &Display, rules: &Rules) -> Class {
    if !w.visible() {
        return Class::Ignored(Ignored::Hidden);
    }
    if w.cloaked != 0 {
        return Class::Ignored(Ignored::Cloaked);
    }
    let rect = w.effective_rect();
    if !w.minimized() {
        if rect.is_empty() {
            return Class::Ignored(Ignored::Empty);
        }
        if !rect.intersects(&display.rect) {
            return Class::Ignored(Ignored::Offscreen);
        }
    }

    let mut has_alpha = w.has_ex(ex_style::LAYERED);
    let mut rule_kind = None;
    let mut rule_name = None;
    if let Some(rule) = rules.find(w) {
        match rule.effect {
            Effect::Ignore => return Class::Ignored(Ignored::Rule(rule.name.clone())),
            Effect::Kind { kind, has_alpha: a } => {
                rule_kind = Some(kind);
                rule_name = Some(rule.name.clone());
                if let Some(a) = a {
                    has_alpha = a;
                }
            }
            Effect::HasAlpha(a) => has_alpha = a,
        }
    }

    let frameless = !w.has_caption() && !w.has(style::THICKFRAME) && !w.has(style::SYSMENU) && !w.has(style::MINIMIZEBOX);
    let appwindow = w.has_ex(ex_style::APPWINDOW);
    let fullscreen_shape = w.owner == 0 && frameless && !w.minimized() && rect == display.rect;

    let kind = rule_kind.unwrap_or_else(|| {
        if w.has_ex(ex_style::NOACTIVATE) && !appwindow {
            Kind::Popup
        } else if w.owner == 0 && w.has(style::POPUP) && frameless && !appwindow && !fullscreen_shape {
            // Splash screens are often tool windows (no taskbar button), so
            // this comes before the tool-window rule; pass 1b demotes it to
            // a popup when the process has another window.
            Kind::Splash
        } else if w.has_ex(ex_style::TOOLWINDOW) && !appwindow && !fullscreen_shape {
            if w.has_caption() { Kind::Tool } else { Kind::Popup }
        } else if w.owner != 0 && !appwindow {
            if w.has_caption() || is_dialog_class(w) { Kind::Dialog } else { Kind::Popup }
        } else if is_dialog_class(w) {
            Kind::Dialog
        } else {
            Kind::Normal
        }
    });

    Class::Mirrored(Mirrored {
        kind,
        owner: 0,
        rect,
        resizable: w.has(style::THICKFRAME),
        topmost: w.has_ex(ex_style::TOPMOST),
        has_alpha,
        fullscreen: kind == Kind::Normal && fullscreen_shape,
        rule: rule_name,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const DISPLAY: Display = Display { rect: Rect::new(0, 0, 1920, 1080), work_area: Rect::new(0, 0, 1920, 1032) };
    const OVERLAPPED: u32 = style::VISIBLE | style::CAPTION | style::SYSMENU | style::THICKFRAME | style::MINIMIZEBOX | style::MAXIMIZEBOX;

    fn w(hwnd: u64, class: &str, style: u32) -> RawWindow {
        RawWindow { hwnd, class: class.into(), style, pid: 100, rect: Rect::new(10, 10, 400, 300), ..Default::default() }
    }

    fn labels(ws: &[RawWindow]) -> Vec<String> {
        classify(ws, &DISPLAY, &Rules::defaults()).iter().map(Class::label).collect()
    }

    #[test]
    fn hidden_cloaked_empty_offscreen() {
        let mut cloaked = w(2, "App", OVERLAPPED);
        cloaked.cloaked = 2;
        let mut empty = w(3, "App", OVERLAPPED);
        empty.rect.w = 0;
        let mut off = w(4, "App", OVERLAPPED);
        off.rect = Rect::new(-32000, -32000, 160, 28);
        assert_eq!(
            labels(&[w(1, "App", OVERLAPPED & !style::VISIBLE), cloaked, empty, off]),
            ["ignore:hidden", "ignore:cloaked", "ignore:empty", "ignore:offscreen"]
        );
    }

    #[test]
    fn minimised_window_keeps_its_restore_rect() {
        let mut m = w(1, "App", OVERLAPPED | style::MINIMIZE);
        m.rect = Rect::new(-32000, -32000, 160, 28);
        m.restore_rect = Some(Rect::new(50, 60, 700, 500));
        let c = classify(&[m], &DISPLAY, &Rules::defaults());
        let m = c[0].mirrored().unwrap();
        assert_eq!((m.kind, m.rect), (Kind::Normal, Rect::new(50, 60, 700, 500)));
    }

    #[test]
    fn owner_chain_skips_hidden_owners() {
        // main (mirrored) <- hidden helper <- dialog
        let main = w(1, "App", OVERLAPPED);
        let mut helper = w(2, "Helper", 0);
        helper.owner = 1;
        let mut dialog = w(3, DIALOG_CLASS, style::VISIBLE | style::POPUP | style::CAPTION | style::SYSMENU);
        dialog.owner = 2;
        let ws = [dialog, helper, main];
        let c = classify(&ws, &DISPLAY, &Rules::defaults());
        assert_eq!(c[0].mirrored().unwrap().owner, 1);
    }

    #[test]
    fn main_window_owned_by_hidden_app_window_is_normal() {
        let hidden_app = w(1, "TApplication", style::POPUP);
        let mut form = w(2, "TForm1", OVERLAPPED);
        form.owner = 1;
        let c = classify(&[form, hidden_app], &DISPLAY, &Rules::defaults());
        let m = c[0].mirrored().unwrap();
        assert_eq!((m.kind, m.owner), (Kind::Normal, 0));
    }

    #[test]
    fn owner_cycle_terminates() {
        let mut a = w(1, "A", 0);
        a.owner = 2;
        let mut b = w(2, "B", 0);
        b.owner = 1;
        let mut d = w(3, DIALOG_CLASS, style::VISIBLE | style::POPUP | style::CAPTION);
        d.owner = 1;
        let c = classify(&[d, a, b], &DISPLAY, &Rules::defaults());
        assert_eq!(c[0].mirrored().unwrap().owner, 0);
    }

    #[test]
    fn frameless_popup_is_splash_only_while_alone() {
        let splash = w(1, "Splash", style::VISIBLE | style::POPUP);
        assert_eq!(labels(std::slice::from_ref(&splash)), ["splash"]);
        assert_eq!(labels(&[splash, w(2, "Main", OVERLAPPED)]), ["popup", "normal"]);
    }

    #[test]
    fn borderless_fullscreen_is_normal_and_flagged() {
        let mut game = w(1, "UnityWndClass", style::VISIBLE | style::POPUP);
        game.rect = DISPLAY.rect;
        game.ex_style = ex_style::TOPMOST;
        let c = classify(&[game], &DISPLAY, &Rules::defaults());
        let m = c[0].mirrored().unwrap();
        assert_eq!((m.kind, m.fullscreen, m.topmost), (Kind::Normal, true, true));
    }

    #[test]
    fn rule_kind_and_alpha() {
        let rules = Rules::with_overrides(
            "[[rule]]\nname = \"palette\"\nclass = \"Palette\"\nkind = \"tool\"\nhas_alpha = true\n",
        )
        .unwrap();
        let c = classify(&[w(1, "Palette", OVERLAPPED)], &DISPLAY, &rules);
        let m = c[0].mirrored().unwrap();
        assert_eq!((m.kind, m.has_alpha, m.rule.as_deref()), (Kind::Tool, true, Some("palette")));
    }
}
