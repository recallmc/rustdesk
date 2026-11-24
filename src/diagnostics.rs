//! Support diagnostics that a normal user can read and send.
//!
//! The regular log of the service process lives under the service account's profile
//! (`C:\Windows\ServiceProfiles\...`), which needs administrator rights just to open. When the
//! controlled machine is locked, that service is the process that handles the connection, so the
//! interesting lines are exactly the ones a user cannot reach.
//!
//! This writes a small, rotating file next to the executable (`<install dir>\diagnostics\`)
//! instead: it keeps the system drive clean and lands where people look for program files. A
//! read-only install falls back to `%ProgramData%\RustDesk\diagnostics`, which every local user
//! can read.
//!
//! Never write secrets here: passwords are only ever logged by length.

use std::io::Write;
use std::path::PathBuf;

/// Keep the file small enough to paste into a chat window.
const MAX_BYTES: u64 = 512 * 1024;

/// Resolved once per process: the directory is not going to change under us.
static DIR: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();

fn diagnostics_dir() -> Option<PathBuf> {
    DIR.get_or_init(resolve_dir).clone()
}

fn resolve_dir() -> Option<PathBuf> {
    // Prefer the install directory: it is the place a user looks for program files, and on a
    // machine with a small system drive it keeps diagnostics off C:. The service runs as SYSTEM so
    // it can write under Program Files; a user-writable install (portable) works too.
    if let Some(install_dir) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("diagnostics")))
    {
        if make_writable(&install_dir) {
            return Some(install_dir);
        }
    }
    // Fallback for read-only installs: ProgramData is world-readable and writable by the service.
    #[cfg(windows)]
    {
        let base = std::env::var("ProgramData").ok().filter(|v| !v.is_empty())?;
        let dir = PathBuf::from(base).join("RustDesk").join("diagnostics");
        if make_writable(&dir) {
            return Some(dir);
        }
        None
    }
    #[cfg(not(windows))]
    {
        let dir = std::env::temp_dir().join("rustdesk-diagnostics");
        if make_writable(&dir) {
            return Some(dir);
        }
        None
    }
}

/// Creates `dir` and proves it is writable, so a later write does not fail silently.
fn make_writable(dir: &PathBuf) -> bool {
    if std::fs::create_dir_all(dir).is_err() {
        return false;
    }
    let probe = dir.join(".write-test");
    match std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&probe)
    {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
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
