//! Log lines for the agent processes: stderr plus an optional file.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

static LOG: Mutex<Option<File>> = Mutex::new(None);

/// Also write log lines to `path` (appended; the folder is created).
pub fn log_to_file(path: &Path) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let f = OpenOptions::new().create(true).append(true).open(path)?;
    *LOG.lock().unwrap_or_else(|e| e.into_inner()) = Some(f);
    Ok(())
}

/// One log line: stderr, and the log file if one is set.
pub fn log(line: &str) {
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let text = format!("{}.{:03} {line}\n", t.as_secs(), t.subsec_millis());
    eprint!("{text}");
    if let Some(f) = LOG.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        let _ = f.write_all(text.as_bytes());
    }
}
