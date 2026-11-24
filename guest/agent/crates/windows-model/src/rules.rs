//! `rules.toml`: per-app and per-class classification overrides (docs/05,
//! "Which windows are mirrored"). The defaults ship inside the agent
//! (`crates/windows-model/rules.toml`, embedded at build time); an override
//! file on the tools ISO (`/agent/rules.toml`) is checked first, so it can
//! correct a default without an agent rebuild.
//!
//! ```toml
//! [[rule]]
//! name = "taskbar"            # required, shown in diagnostics
//! class = "Shell_TrayWnd"     # matchers: class, process, aumid, title (all given must match)
//! ignore = true               # effect: ignore = true, or kind = "...", or has_alpha
//! ```
//!
//! - `class`: window class, exact, case-insensitive.
//! - `process`: executable file name (`steam.exe`), case-insensitive.
//! - `aumid`: AppUserModelID, case-insensitive.
//! - `title`: window title, exact (case-sensitive).
//! - `kind`: one of `normal`, `dialog`, `menu`, `tooltip`, `popup`,
//!   `splash`, `tool`.
//! - `has_alpha`: force the flag (layered windows already set it).
//!
//! Rules apply to windows that are visible, uncloaked and have an area; the
//! first matching rule wins. Unknown keys are errors, so a typo cannot
//! silently disable a rule.

use serde::Deserialize;

use crate::Kind;
use crate::raw::RawWindow;

/// The rules compiled into the agent.
pub const DEFAULT_RULES: &str = include_str!("../rules.toml");

/// Caps, because the override file comes from outside the binary.
pub const MAX_RULES: usize = 1024;
pub const MAX_FIELD_LEN: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    pub name: String,
    class: Option<String>,
    process: Option<String>,
    aumid: Option<String>,
    title: Option<String>,
    pub effect: Effect,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    Ignore,
    Kind { kind: Kind, has_alpha: Option<bool> },
    HasAlpha(bool),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Rules {
    rules: Vec<Rule>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct RulesError(pub String);

impl std::fmt::Display for RulesError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "rules.toml: {}", self.0)
    }
}
impl std::error::Error for RulesError {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    #[serde(default)]
    rule: Vec<RuleToml>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RuleToml {
    name: String,
    class: Option<String>,
    process: Option<String>,
    aumid: Option<String>,
    title: Option<String>,
    ignore: Option<bool>,
    kind: Option<String>,
    has_alpha: Option<bool>,
}

impl Rules {
    /// The embedded defaults. They are tested, so this cannot fail at run time.
    pub fn defaults() -> Self {
        Self::parse(DEFAULT_RULES).expect("embedded rules.toml is valid")
    }

    /// `overrides` first, then the defaults.
    pub fn with_overrides(overrides: &str) -> Result<Self, RulesError> {
        let mut rules = Self::parse(overrides)?;
        rules.rules.extend(Self::defaults().rules);
        Ok(rules)
    }

    pub fn parse(text: &str) -> Result<Self, RulesError> {
        let file: File = toml::from_str(text).map_err(|e| RulesError(e.to_string()))?;
        if file.rule.len() > MAX_RULES {
            return Err(RulesError(format!("{} rules, at most {MAX_RULES}", file.rule.len())));
        }
        let rules = file.rule.into_iter().map(Rule::from_toml).collect::<Result<_, _>>()?;
        Ok(Self { rules })
    }

    pub fn len(&self) -> usize {
        self.rules.len()
    }
    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    /// The first rule matching `w`, if any.
    pub fn find(&self, w: &RawWindow) -> Option<&Rule> {
        let process = w.process_name();
        self.rules.iter().find(|r| r.matches(w, &process))
    }
}

impl Rule {
    fn from_toml(t: RuleToml) -> Result<Self, RulesError> {
        let name = t.name.trim().to_string();
        if name.is_empty() {
            return Err(RulesError("a rule has an empty name".into()));
        }
        let err = |m: &str| RulesError(format!("rule {name:?}: {m}"));
        for v in [&t.class, &t.process, &t.aumid, &t.title].into_iter().flatten() {
            if v.is_empty() || v.len() > MAX_FIELD_LEN {
                return Err(err("matchers must be 1-256 bytes"));
            }
        }
        if name.len() > MAX_FIELD_LEN {
            return Err(err("name longer than 256 bytes"));
        }
        if t.class.is_none() && t.process.is_none() && t.aumid.is_none() && t.title.is_none() {
            return Err(err("needs at least one of class, process, aumid, title"));
        }
        let effect = match (t.ignore, t.kind, t.has_alpha) {
            (Some(true), None, None) => Effect::Ignore,
            (Some(false), _, _) => return Err(err("`ignore = false` does nothing; remove it")),
            (Some(true), _, _) => return Err(err("`ignore` cannot be combined with other effects")),
            (None, Some(k), a) => Effect::Kind {
                kind: Kind::from_name(&k).ok_or_else(|| err(&format!("unknown kind {k:?}")))?,
                has_alpha: a,
            },
            (None, None, Some(a)) => Effect::HasAlpha(a),
            (None, None, None) => return Err(err("needs an effect: ignore, kind or has_alpha")),
        };
        Ok(Self {
            name,
            class: t.class.map(|s| s.to_lowercase()),
            process: t.process.map(|s| s.to_lowercase()),
            aumid: t.aumid.map(|s| s.to_lowercase()),
            title: t.title,
            effect,
        })
    }

    fn matches(&self, w: &RawWindow, process_name: &str) -> bool {
        let ci = |want: &Option<String>, have: &str| want.as_ref().is_none_or(|v| v == &have.to_lowercase());
        ci(&self.class, &w.class)
            && self.process.as_ref().is_none_or(|v| v == process_name)
            && ci(&self.aumid, w.aumid.as_deref().unwrap_or(""))
            && self.title.as_ref().is_none_or(|v| v == &w.title)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn win(class: &str, process: &str) -> RawWindow {
        RawWindow { class: class.into(), process: process.into(), ..Default::default() }
    }

    #[test]
    fn defaults_parse() {
        let r = Rules::defaults();
        assert!(r.len() > 10);
        assert_eq!(r.find(&win("shell_traywnd", r"C:\Windows\explorer.exe")).unwrap().effect, Effect::Ignore);
        assert_eq!(
            r.find(&win("#32768", "")).unwrap().effect,
            Effect::Kind { kind: Kind::Menu, has_alpha: None }
        );
        assert!(r.find(&win("Notepad", "")).is_none());
    }

    #[test]
    fn process_matches_file_name_case_insensitively() {
        let r = Rules::parse("[[rule]]\nname = \"x\"\nprocess = \"Steam.exe\"\nkind = \"tool\"\n").unwrap();
        assert!(r.find(&win("Any", r"C:\Program Files (x86)\Steam\STEAM.EXE")).is_some());
        assert!(r.find(&win("Any", r"C:\steam.exe.bak\other.exe")).is_none());
    }

    #[test]
    fn overrides_come_first() {
        let r = Rules::with_overrides("[[rule]]\nname = \"menu as popup\"\nclass = \"#32768\"\nkind = \"popup\"\n")
            .unwrap();
        assert_eq!(r.find(&win("#32768", "")).unwrap().name, "menu as popup");
    }

    #[test]
    fn rejects_bad_files() {
        for (text, why) in [
            ("[[rule]]\nname = \"a\"\nclass = \"X\"\n", "needs an effect"),
            ("[[rule]]\nname = \"a\"\nignore = true\n", "at least one of"),
            ("[[rule]]\nname = \"a\"\nclass = \"X\"\nkind = \"window\"\n", "unknown kind"),
            ("[[rule]]\nname = \"a\"\nclass = \"X\"\nignroe = true\n", "unknown field"),
            ("[[rule]]\nname = \"a\"\nclass = \"X\"\nignore = true\nkind = \"menu\"\n", "cannot be combined"),
            ("[[rule]]\nname = \" \"\nclass = \"X\"\nignore = true\n", "empty name"),
            ("[[rule]]\nname = \"a\"\nclass = \"\"\nignore = true\n", "1-256 bytes"),
        ] {
            let e = Rules::parse(text).unwrap_err().to_string();
            assert!(e.contains(why), "{text:?}: {e}");
        }
    }

    #[test]
    fn caps_rule_count() {
        let text = "[[rule]]\nname = \"a\"\nclass = \"X\"\nignore = true\n".repeat(MAX_RULES + 1);
        assert!(Rules::parse(&text).unwrap_err().0.contains("at most"));
    }
}
