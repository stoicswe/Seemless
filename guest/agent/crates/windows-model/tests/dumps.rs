//! WP5.1 acceptance: recorded window dumps from 10 common apps classify as
//! expected. The dumps are in tests/data (format: tests/data/README.md).
//! They are synthetic until a real guest captures them (see the README).

use std::path::PathBuf;

use windows_model::dump::{Dump, Origin};
use windows_model::{Kind, Rules, Tracker};

const APPS: [&str; 10] = [
    "notepad",
    "explorer",
    "file-open",
    "settings-uwp",
    "terminal",
    "electron-vscode",
    "steam-custom-chrome",
    "console",
    "office-dialogs",
    "splash",
];

fn data(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data").join(format!("{name}.json"))
}

fn load(name: &str) -> Dump {
    let text = std::fs::read_to_string(data(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    Dump::from_json(&text).unwrap_or_else(|e| panic!("{name}: {e}"))
}

#[test]
fn ten_apps_classify_as_expected() {
    let rules = Rules::defaults();
    let mut failures = Vec::new();
    let mut windows = 0;
    for app in APPS {
        let dump = load(app);
        windows += dump.windows.len();
        let m = dump.mismatches(&rules);
        println!("{app:<22} {:>2} windows  {}", dump.windows.len(), if m.is_empty() { "ok" } else { "MISMATCH" });
        failures.extend(m.into_iter().map(|m| format!("{app}: {m}")));
    }
    println!("{} dumps, {windows} windows", APPS.len());
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

#[test]
fn every_dump_in_the_folder_is_listed_and_marked_synthetic_or_captured() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data");
    let mut found: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| {
            let p = e.unwrap().path();
            (p.extension()? == "json").then(|| p.file_stem().unwrap().to_string_lossy().into_owned())
        })
        .collect();
    found.sort();
    let mut listed: Vec<String> = APPS.iter().map(|s| s.to_string()).collect();
    listed.sort();
    assert_eq!(found, listed, "add new dumps to APPS");
    for app in APPS {
        let d = load(app);
        if d.origin == Origin::Synthetic {
            assert!(d.note.as_deref().unwrap_or("").contains("Not captured"), "{app}: synthetic dumps must say so");
        }
    }
}

#[test]
fn dumps_round_trip_through_the_capture_format() {
    for app in APPS {
        let d = load(app);
        assert_eq!(Dump::from_json(&d.to_json()).unwrap(), d, "{app}");
    }
}

/// What the host receives for each dump: the snapshot WP4.2 sends as-is.
#[test]
fn snapshots_are_valid_for_the_host() {
    let rules = Rules::defaults();
    for app in APPS {
        let d = load(app);
        let mut t = Tracker::new(rules.clone());
        let s = t.snapshot(&d.display, &d.raw_windows());
        assert!(!s.windows.is_empty(), "{app}: nothing mirrored");
        let ids: Vec<u64> = s.windows.iter().map(|w| w.id).collect();
        for (i, w) in s.windows.iter().enumerate() {
            assert_ne!(w.id, 0, "{app}");
            assert_ne!(w.id, w.owner_id, "{app}");
            assert!(!w.app_key.is_empty(), "{app}: window {} has no app_key", w.id);
            assert_ne!(w.icon_id, 0, "{app}");
            assert!(w.rect.is_some() && w.flags.is_some(), "{app}");
            // Back to front: an owner is behind (earlier than) what it owns.
            if w.owner_id != 0 {
                let at = ids.iter().position(|id| *id == w.owner_id).expect("owner is in the snapshot");
                assert!(at < i, "{app}: owner {} after window {}", w.owner_id, w.id);
            }
        }
        // A second update from the same list sends nothing.
        assert!(t.update(&d.display, &d.raw_windows()).is_empty(), "{app}");
    }
}

#[test]
fn uwp_app_key_is_the_hosted_app_not_application_frame_host() {
    let d = load("settings-uwp");
    let s = Tracker::new(Rules::defaults()).snapshot(&d.display, &d.raw_windows());
    assert_eq!(s.windows.len(), 1);
    assert_eq!(s.windows[0].app_key, "windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel");
}

#[test]
fn kinds_seen_across_the_dumps_cover_the_catalogue() {
    let rules = Rules::defaults();
    let mut seen = std::collections::HashSet::new();
    for app in APPS {
        for c in load(app).classify(&rules) {
            if let Some(m) = c.mirrored() {
                seen.insert(m.kind);
            }
        }
    }
    // Tool windows (floating palettes) have no dump yet; unit-tested instead.
    for k in Kind::ALL.into_iter().filter(|k| *k != Kind::Tool) {
        assert!(seen.contains(&k), "no dump shows a {k:?} window");
    }
}

/// One app, one Dock group: Office sets its AUMID on the main window only,
/// so dialogs and popups must inherit it rather than fall back to the path.
#[test]
fn owned_windows_share_their_apps_key() {
    for (app, pid, want) in [
        ("office-dialogs", 13300, "microsoft.office.winword.exe.15"),
        ("file-open", 7340, r"c:\windows\regedit.exe"),
        ("electron-vscode", 10240, "microsoft.visualstudiocode"),
    ] {
        let d = load(app);
        let s = Tracker::new(Rules::defaults()).snapshot(&d.display, &d.raw_windows());
        let keys: Vec<&str> = s.windows.iter().filter(|w| w.pid == pid).map(|w| w.app_key.as_str()).collect();
        assert!(keys.len() > 1, "{app}");
        assert!(keys.iter().all(|k| *k == want), "{app}: {keys:?}");
    }
}

/// Data sanity: Windows keeps owned windows above their owners, so a
/// realistic front-to-back dump lists each visible owned window before its
/// owner,
/// and only minimisable windows carry WS_MAXIMIZE.
#[test]
fn dumps_are_realistic() {
    use windows_model::raw::style;
    for app in APPS {
        let d = load(app);
        let pos = |h: u64| d.windows.iter().position(|w| w.raw.hwnd == h);
        for (i, w) in d.windows.iter().enumerate() {
            if let Some(o) = pos(w.raw.owner).filter(|_| w.raw.visible()) {
                assert!(i < o, "{app}: 0x{:X} is listed behind its owner", w.raw.hwnd);
            }
            if w.raw.maximized() {
                assert!(w.raw.has(style::MAXIMIZEBOX), "{app}: 0x{:X} maximised without a maximise box", w.raw.hwnd);
            }
        }
    }
}
