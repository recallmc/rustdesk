//! Support diagnostics that a normal user can read and send.
//!
//! The regular log of the service process lives under the service account's profile
//! (`C:\Windows\ServiceProfiles\...`), which needs administrator rights just to open. When the
//! controlled machine is locked, that service is the process that handles the connection, so the
//! interesting lines are exactly the ones a user cannot reach.
//!
//! This writes a small, rotating file under `%ProgramData%` instead. ProgramData is readable by
//! every local user, so the file can be attached to a bug report without elevation.
//!
//! Never write secrets here: passwords are only ever logged by length.

use std::io::Write;
use std::path::PathBuf;

/// Keep the file small enough to paste into a chat window.
const MAX_BYTES: u64 = 512 * 1024;

fn diagnostics_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        let base = std::env::var("ProgramData").ok().filter(|v| !v.is_empty())?;
        Some(PathBuf::from(base).join("RustDesk").join("diagnostics"))
    }
    #[cfg(not(windows))]
    {
        Some(std::env::temp_dir().join("rustdesk-diagnostics"))
    }
}

/// Full path of a category file, for messages that tell the user where to look.
pub fn path(category: &str) -> Option<PathBuf> {
    Some(diagnostics_dir()?.join(format!("{category}.log")))
}

/// Append one timestamped line. Failures are ignored: diagnostics must never break a session.
pub fn log(category: &str, message: &str) {
    let Some(dir) = diagnostics_dir() else {
        return;
    };
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let file = dir.join(format!("{category}.log"));
    if let Ok(meta) = std::fs::metadata(&file) {
        if meta.len() > MAX_BYTES {
            // One generation is enough to keep the current run and the previous one.
            let _ = std::fs::rename(&file, dir.join(format!("{category}.log.1")));
        }
    }
    let now = hbb_common::chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&file)
    {
        let _ = writeln!(f, "[{now}] {message}");
    }
}
