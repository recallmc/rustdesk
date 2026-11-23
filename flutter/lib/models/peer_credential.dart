/// A credential saved for one peer.
///
/// Mirrors `src/credential_store.rs::PeerCredential`. Note that the secrets are **decrypted**
/// only for the few milliseconds between `CredentialStore.read()` and `gFFI.login()`; the JSON
/// returned by Rust must never be logged, cached in a file, or shown in the UI.
enum PeerCredentialState { active, stale, disabled }

class PeerCredential {
  final int schemaVersion;
  final String id;
  final String accessSecret;
  final String osUsername;
  final String osSecret;
  final String label;
  final bool biometricRequired;
  final int failCount;
  final int lockedUntilMs;
  final PeerCredentialState state;
  final int createdAtMs;
  final int updatedAtMs;
  final int lastUsedAtMs;

  const PeerCredential({
    required this.id,
    required this.accessSecret,
    this.schemaVersion = 1,
    this.osUsername = '',
    this.osSecret = '',
    this.label = '',
    this.biometricRequired = true,
    this.failCount = 0,
    this.lockedUntilMs = 0,
    this.state = PeerCredentialState.active,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.lastUsedAtMs = 0,
  });

  static PeerCredentialState _parseState(String? value) {
    switch (value) {
      case 'stale':
        return PeerCredentialState.stale;
      case 'disabled':
        return PeerCredentialState.disabled;
      default:
        return PeerCredentialState.active;
    }
  }

  factory PeerCredential.fromJson(Map<String, dynamic> json) {
    return PeerCredential(
      id: (json['id'] as String?) ?? '',
      accessSecret: (json['access_secret'] as String?) ?? '',
      schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
      osUsername: (json['os_username'] as String?) ?? '',
      osSecret: (json['os_secret'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      biometricRequired: json['biometric_required'] as bool? ?? true,
      failCount: (json['fail_count'] as num?)?.toInt() ?? 0,
      lockedUntilMs: (json['locked_until_ms'] as num?)?.toInt() ?? 0,
      state: _parseState(json['state'] as String?),
      createdAtMs: (json['created_at_ms'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
      lastUsedAtMs: (json['last_used_at_ms'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isLocked => lockedUntilMs > DateTime.now().millisecondsSinceEpoch;

  bool get canAutoSubmit =>
      state == PeerCredentialState.active &&
      accessSecret.isNotEmpty &&
      !isLocked;
}
