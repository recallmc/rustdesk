//! "Start on boot" for the Windows client.
//!
//! The installer drops a `<app> Tray.lnk` shortcut into the all-users Startup folder, but there is
//! no way to turn that off again once it is there. This module manages the very same shortcut so
//! the setting in the UI and the actual boot behaviour stay in sync.

use super::{installer_shell, ResultType};
use hbb_common::{bail, log};
use std::path::PathBuf;

/// Name of the shortcut the installer uses for the tray process.
fn shortcut_name() -> String {
    format!("{} Tray.lnk", crate::get_app_name())
}

/// `%ProgramData%\Microsoft\Windows\Start Menu\Programs\Startup\<app> Tray.lnk`
///
/// The all-users Startup folder is used on purpose: it is where the installer puts the shortcut,
/// so the same file is toggled instead of adding a second, competing autostart mechanism.
fn startup_shortcut_path() -> ResultType<PathBuf> {
    let program_data = match std::env::var("ProgramData") {
        Ok(v) if !v.is_empty() => v,
        _ => bail!("ProgramData is not set"),
    };
    Ok(PathBuf::from(program_data)
        .join("Microsoft")
        .join("Windows")
        .join("Start Menu")
        .join("Programs")
        .join("Startup")
        .join(shortcut_name()))
}

/// Whether the client is registered to start with the user session.
pub fn get_start_on_boot() -> bool {
    match startup_shortcut_path() {
        Ok(path) => path.exists(),
        Err(e) => {
            log::warn!("Failed to resolve the startup shortcut: {}", e);
            false
        }
    }
}

/// Add or remove the startup shortcut.
pub fn set_start_on_boot(enable: bool) -> ResultType<()> {
    let path = startup_shortcut_path()?;
    if enable {
        if path.exists() {
            return Ok(());
        }
        let exe = std::env::current_exe()?;
        let bytes =
            installer_shell::shortcut_bytes(exe.to_string_lossy().as_ref(), Some("--tray"), None)?;
        std::fs::write(&path, bytes)?;
        log::info!("Enabled start on boot: {}", path.display());
    } else {
        if path.exists() {
            std::fs::remove_file(&path)?;
            log::info!("Disabled start on boot: {}", path.display());
        }
    }
    Ok(())
}
