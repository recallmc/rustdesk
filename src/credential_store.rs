//! Per-peer login credentials for the mobile "one-tap sign in" feature.
//!
//! Secrets are encrypted at rest with the device-bound key already used by
//! [`hbb_common::password_security`] and are only decrypted when the UI is about to submit them,
//! so nothing readable is ever written to disk.
//!
//! The module is deliberately free of `#[cfg]` platform switches: it is plain file storage so it
//! works the same on Android, Windows and Linux, and it adds no new dependency to the build.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use hbb_common::config::Config;
use hbb_common::log;
use hbb_common::password_security::{decrypt_str_or_original, encrypt_str_or_original};
use serde::{Deserialize, Serialize};

/// Sub directory of the config directory; one JSON file per peer.
const DIR_NAME: &str = "peer_credentials";
const SCHEMA_VERSION: u32 = 1;
/// Guards against a pathological paste; real passwords are far shorter.
const MAX_SECRET_LEN: usize = 512;
/// The only format `password_security` currently encrypts with.
const ENC_VERSION: &str = "00";

const STATE_ACTIVE: &str = "active";
const STATE_STALE: &str = "stale";
const STATE_DISABLED: &str = "disabled";

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn default_true() -> bool {
    true
}

/// One saved credential per peer.
///
/// `access_secret` and `os_secret` hold *ciphertext* while the record is on disk; they are only
/// decrypted by [`load`] for immediate handing to the UI.
#[derive(Serialize, Deserialize, Clone)]
pub struct PeerCredential {
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    pub id: String,
    #[serde(default)]
    pub access_secret: String,
    #[serde(default)]
    pub os_username: String,
    #[serde(default)]
    pub os_secret: String,
    #[serde(default)]
    pub label: String,
    #[serde(default = "default_true")]
    pub biometric_required: bool,
    #[serde(default)]
    pub fail_count: u32,
    #[serde(default)]
    pub locked_until_ms: i64,
    #[serde(default = "default_state")]
    pub state: String,
    #[serde(default)]
    pub created_at_ms: i64,
    #[serde(default)]
    pub updated_at_ms: i64,
    #[serde(default)]
    pub last_used_at_ms: i64,
}

fn default_schema_version() -> u32 {
    SCHEMA_VERSION
}

fn default_state() -> String {
    STATE_ACTIVE.to_owned()
}

impl Default for PeerCredential {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            id: String::new(),
            access_secret: String::new(),
            os_username: String::new(),
            os_secret: String::new(),
            label: String::new(),
            biometric_required: true,
            fail_count: 0,
            locked_until_ms: 0,
            state: default_state(),
            created_at_ms: 0,
            updated_at_ms: 0,
            last_used_at_ms: 0,
        }
    }
}

fn normalize_state(state: &str) -> Option<&'static str> {
    match state {
        STATE_ACTIVE => Some(STATE_ACTIVE),
        STATE_STALE => Some(STATE_STALE),
        STATE_DISABLED => Some(STATE_DISABLED),
        _ => None,
    }
}

/// Peer ids are numeric in practice; anything that could escape the directory is rewritten to `_`.
/// The id is stored inside the record and compared on read, so a rewrite can only cause a miss,
/// never a wrong match.
fn file_stem(id: &str) -> String {
    id.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn dir(base: &Path) -> PathBuf {
    base.join(DIR_NAME)
}

fn record_path(base: &Path, id: &str) -> PathBuf {
    dir(base).join(format!("{}.json", file_stem(id)))
}

fn validate_id(id: &str) -> Result<(), String> {
    if id.is_empty() {
        return Err("empty peer id".to_owned());
    }
    if id.len() > 128 {
        return Err("peer id too long".to_owned());
    }
    Ok(())
}

/// Encrypts, refusing to silently fall back to plaintext (which is what `*_or_original` does when
/// the input is too long or the ciphertext would be ambiguous).
fn seal(plain: &str) -> Result<String, String> {
    if plain.is_empty() {
        return Ok(String::new());
    }
    let sealed = encrypt_str_or_original(plain, ENC_VERSION, MAX_SECRET_LEN);
    if sealed == plain {
        return Err("failed to encrypt secret".to_owned());
    }
    Ok(sealed)
}

fn open(sealed: &str) -> String {
    if sealed.is_empty() {
        return String::new();
    }
    let (plain, ok, _) = decrypt_str_or_original(sealed, ENC_VERSION);
    if !ok {
        // Treat an unreadable secret as "not configured" rather than handing garbage to the
        // login request.
        log::warn!("stored peer credential cannot be decrypted; ignoring it");
        return String::new();
    }
    plain
}

fn read_record(base: &Path, id: &str) -> Option<PeerCredential> {
    let path = record_path(base, id);
    let text = fs::read_to_string(&path).ok()?;
    let record: PeerCredential = match serde_json::from_str(&text) {
        Ok(record) => record,
        Err(err) => {
            log::warn!("invalid peer credential {}: {}", path.display(), err);
            return None;
        }
    };
    if record.id != id {
        return None;
    }
    if record.schema_version > SCHEMA_VERSION {
        log::warn!(
            "peer credential {} has a newer schema; ignoring",
            record.id
        );
        return None;
    }
    Some(record)
}

fn write_record(base: &Path, record: &PeerCredential) -> Result<(), String> {
    let dir = dir(base);
    fs::create_dir_all(&dir).map_err(|e| format!("create {}: {}", dir.display(), e))?;
    let path = record_path(base, &record.id);
    let text = serde_json::to_string_pretty(record).map_err(|e| e.to_string())?;
    // Write-then-rename so a crash cannot leave a half written record behind.
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, text).map_err(|e| format!("write {}: {}", tmp.display(), e))?;
    fs::rename(&tmp, &path).map_err(|e| format!("replace {}: {}", path.display(), e))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// Stores (or replaces) the credential of `id`. Secrets are encrypted before they touch the disk.
pub fn save(
    base: &Path,
    id: &str,
    access_secret: &str,
    os_username: &str,
    os_secret: &str,
    label: &str,
    biometric_required: bool,
) -> Result<(), String> {
    validate_id(id)?;
    if access_secret.is_empty() {
        return Err("empty access secret".to_owned());
    }
    let existing = read_record(base, id);
    let now = now_ms();
    let record = PeerCredential {
        schema_version: SCHEMA_VERSION,
        id: id.to_owned(),
        access_secret: seal(access_secret)?,
        os_username: os_username.to_owned(),
        os_secret: seal(os_secret)?,
        label: label.to_owned(),
        biometric_required,
        fail_count: 0,
        locked_until_ms: 0,
        state: STATE_ACTIVE.to_owned(),
        created_at_ms: existing
            .as_ref()
            .map(|r| r.created_at_ms)
            .filter(|v| *v > 0)
            .unwrap_or(now),
        updated_at_ms: now,
        last_used_at_ms: existing.map(|r| r.last_used_at_ms).unwrap_or(0),
    };
    write_record(base, &record)
}

/// Returns the record with decrypted secrets, or `None` when nothing is configured.
pub fn load(base: &Path, id: &str) -> Option<PeerCredential> {
    let mut record = read_record(base, id)?;
    record.access_secret = open(&record.access_secret);
    record.os_secret = open(&record.os_secret);
    if record.access_secret.is_empty() {
        return None;
    }
    Some(record)
}

pub fn delete(base: &Path, id: &str) -> bool {
    let path = record_path(base, id);
    match fs::remove_file(&path) {
        Ok(_) => true,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => true,
        Err(err) => {
            log::warn!("remove {}: {}", path.display(), err);
            false
        }
    }
}

pub fn has(base: &Path, id: &str) -> bool {
    read_record(base, id).is_some()
}

pub fn ids(base: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(dir(base)) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        if let Ok(record) = serde_json::from_str::<PeerCredential>(&text) {
            if !record.id.is_empty() {
                out.push(record.id);
            }
        }
    }
    out
}

/// Moves a record between `active` / `stale` / `disabled`.
pub fn set_state(base: &Path, id: &str, state: &str) -> bool {
    let Some(state) = normalize_state(state) else {
        return false;
    };
    let Some(mut record) = read_record(base, id) else {
        return false;
    };
    record.state = state.to_owned();
    record.updated_at_ms = now_ms();
    write_record(base, &record).is_ok()
}

/// Records that the credential was just used successfully.
pub fn touch(base: &Path, id: &str) -> bool {
    let Some(mut record) = read_record(base, id) else {
        return false;
    };
    record.last_used_at_ms = now_ms();
    record.fail_count = 0;
    record.locked_until_ms = 0;
    write_record(base, &record).is_ok()
}

/// Counts a rejected credential and locks it briefly after repeated failures.
///
/// Returns the new failure count. `lock_after` consecutive failures set `locked_until_ms` to
/// `lock_ms` milliseconds ahead, so a shared phone cannot be used to brute force a device.
pub fn record_failure(base: &Path, id: &str, lock_after: u32, lock_ms: i64) -> Option<u32> {
    let mut record = read_record(base, id)?;
    record.fail_count = record.fail_count.saturating_add(1);
    if lock_after > 0 && record.fail_count >= lock_after {
        record.locked_until_ms = now_ms().saturating_add(lock_ms);
    }
    record.updated_at_ms = now_ms();
    write_record(base, &record).ok()?;
    Some(record.fail_count)
}

fn default_base() -> PathBuf {
    Config::path("")
}

// ---------------------------------------------------------------------------
// Public entry points used by the Flutter layer
// ---------------------------------------------------------------------------

pub fn save_default(
    id: &str,
    access_secret: &str,
    os_username: &str,
    os_secret: &str,
    label: &str,
    biometric_required: bool,
) -> bool {
    match save(
        &default_base(),
        id,
        access_secret,
        os_username,
        os_secret,
        label,
        biometric_required,
    ) {
        Ok(_) => true,
        Err(err) => {
            log::error!("save peer credential: {}", err);
            false
        }
    }
}

/// JSON of the record including decrypted secrets, or an empty string when absent.
pub fn load_json_default(id: &str) -> String {
    match load(&default_base(), id) {
        Some(record) => serde_json::to_string(&record).unwrap_or_default(),
        None => String::new(),
    }
}

pub fn delete_default(id: &str) -> bool {
    delete(&default_base(), id)
}

pub fn has_default(id: &str) -> bool {
    has(&default_base(), id)
}

pub fn ids_default() -> Vec<String> {
    ids(&default_base())
}

pub fn set_state_default(id: &str, state: &str) -> bool {
    set_state(&default_base(), id, state)
}

pub fn touch_default(id: &str) -> bool {
    touch(&default_base(), id)
}

pub fn record_failure_default(id: &str) -> u32 {
    record_failure(&default_base(), id, 5, 60_000).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rustdesk-cred-test-{}-{}",
            name,
            now_ms()
        ));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn round_trip_encrypts_the_secret_on_disk() {
        let base = temp_dir("roundtrip");
        assert!(save(&base, "123456789", "s3cr3t-value", "", "", "desk", true).is_ok());

        let raw = fs::read_to_string(record_path(&base, "123456789")).unwrap();
        assert!(!raw.contains("s3cr3t-value"), "secret must not be stored in clear");
        assert!(raw.contains("00"), "expected the encrypted payload marker");

        let record = load(&base, "123456789").unwrap();
        assert_eq!(record.access_secret, "s3cr3t-value");
        assert!(record.biometric_required);
        assert_eq!(record.state, STATE_ACTIVE);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn saves_os_credentials_separately() {
        let base = temp_dir("os");
        save(&base, "42", "access", "Administrator", "os-pass", "lab", false).unwrap();
        let record = load(&base, "42").unwrap();
        assert_eq!(record.os_username, "Administrator");
        assert_eq!(record.os_secret, "os-pass");
        assert!(!record.biometric_required);
        let raw = fs::read_to_string(record_path(&base, "42")).unwrap();
        assert!(!raw.contains("os-pass"));
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn delete_and_ids_follow_the_store() {
        let base = temp_dir("ids");
        assert!(!has(&base, "1"));
        save(&base, "1", "a", "", "", "", true).unwrap();
        save(&base, "2", "b", "", "", "", true).unwrap();
        let mut ids = ids(&base);
        ids.sort();
        assert_eq!(ids, vec!["1".to_owned(), "2".to_owned()]);
        assert!(delete(&base, "1"));
        assert!(!has(&base, "1"));
        // Deleting an absent record is not an error: the outcome the caller wants already holds.
        assert!(delete(&base, "1"));
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn state_transitions_and_usage_are_persisted() {
        let base = temp_dir("state");
        save(&base, "7", "pw", "", "", "", true).unwrap();
        assert!(set_state(&base, "7", STATE_STALE));
        assert_eq!(load(&base, "7").unwrap().state, STATE_STALE);
        assert!(!set_state(&base, "7", "bogus"));
        assert_eq!(record_failure(&base, "7", 2, 1000), Some(1));
        assert_eq!(record_failure(&base, "7", 2, 1000), Some(2));
        let locked = read_record(&base, "7").unwrap();
        assert!(locked.locked_until_ms > now_ms() - 1);
        assert!(touch(&base, "7"));
        let touched = read_record(&base, "7").unwrap();
        assert_eq!(touched.fail_count, 0);
        assert_eq!(touched.locked_until_ms, 0);
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn rejects_empty_secret_and_unsafe_ids_do_not_escape() {
        let base = temp_dir("reject");
        assert!(save(&base, "x", "", "", "", "", true).is_err());
        assert!(save(&base, "", "pw", "", "", "", true).is_err());
        save(&base, "../evil", "pw", "", "", "", true).unwrap();
        // The file must stay inside the directory.
        assert!(record_path(&base, "../evil").starts_with(dir(&base)));
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn record_with_wrong_id_is_ignored() {
        let base = temp_dir("mismatch");
        save(&base, "9", "pw", "", "", "", true).unwrap();
        let path = record_path(&base, "9");
        let text = fs::read_to_string(&path).unwrap();
        fs::write(&path, text.replace("\"id\": \"9\"", "\"id\": \"8\"")).unwrap();
        assert!(load(&base, "9").is_none());
        let _ = fs::remove_dir_all(&base);
    }
}
