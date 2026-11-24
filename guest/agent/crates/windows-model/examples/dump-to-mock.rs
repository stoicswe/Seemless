//! Writes a `seemlessctl mock-agent` script from a window dump, so Zen shows
//! the windows the classifier would mirror, exactly as the agent sends them:
//!
//! ```sh
//! ~/.cargo/bin/cargo run -q --manifest-path guest/agent/Cargo.toml -p windows-model \
//!     --example dump-to-mock -- guest/agent/crates/windows-model/tests/data/office-dialogs.json \
//!     > proto/mock/office-dialogs.json
//! ```
//!
//! Optional second argument: a rules.toml override file.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(path) = args.first() else {
        eprintln!("usage: dump-to-mock <dump.json> [rules-override.toml]");
        std::process::exit(2);
    };
    let fail = |e: String| -> ! {
        eprintln!("dump-to-mock: {e}");
        std::process::exit(1)
    };
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| fail(format!("{path}: {e}")));
    let dump = windows_model::Dump::from_json(&text).unwrap_or_else(|e| fail(e.to_string()));
    let rules = match args.get(1) {
        Some(p) => {
            let t = std::fs::read_to_string(p).unwrap_or_else(|e| fail(format!("{p}: {e}")));
            windows_model::Rules::with_overrides(&t).unwrap_or_else(|e| fail(e.to_string()))
        }
        None => windows_model::Rules::defaults(),
    };
    let script = dump.mock_script(&rules);
    println!("{}", serde_json::to_string_pretty(&script).expect("JSON"));
}
