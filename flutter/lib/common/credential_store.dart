import 'dart:convert';
import 'dart:async';

import '../models/platform_model.dart';
import 'package:get/get.dart';

import '../models/peer_credential.dart';

/// Thin Dart wrapper around the encrypted store in `src/credential_store.rs`.
///
/// The only plaintext a caller ever sees is the credential returned by [read], which is intended
/// to be passed straight to `gFFI.login()` and dropped. Never log it or persist it in Dart.
class CredentialStore {
  CredentialStore._() {
    unawaited(loadIds());
  }

  static final CredentialStore instance = CredentialStore._();

  /// Kept in memory so the peer card can show a "credential configured" badge without an async
  /// secure-store/read on every rebuild. Rx means the badge updates as soon as the load finishes.
  final configuredPeerIds = <String>[].obs;

  /// Peer id -> wall clock ms of a successful local authentication.
  ///
  /// The prompt happens when the user taps the computer, but the password is only needed once the
  /// remote side asks for it (a few seconds later). This short-lived, single-use hand-off keeps the
  /// tap -> fingerprint -> sign-in flow from depending on when that prompt arrives.
  final Map<String, int> _authorizedAt = {};

  void authorize(String peerId) {
    _authorizedAt[peerId] = DateTime.now().millisecondsSinceEpoch;
  }

  /// Consumes a previous authorization. Returns false when it is missing or expired.
  bool consumeAuthorization(String peerId,
      {Duration ttl = const Duration(minutes: 2)}) {
    final at = _authorizedAt.remove(peerId);
    if (at == null) return false;
    return DateTime.now().millisecondsSinceEpoch - at <= ttl.inMilliseconds;
  }

  void clearAuthorization(String peerId) => _authorizedAt.remove(peerId);

  bool has(String peerId) => configuredPeerIds.contains(peerId);

  Future<void> loadIds() async {
    try {
      final ids = await bind.peerCredentialIds();
      configuredPeerIds.assignAll(ids);
    } catch (_) {
      // A read failure must degrade to "not configured", never break the peer list.
      configuredPeerIds.clear();
    }
  }

  Future<PeerCredential?> read(String peerId) async {
    try {
      final json = await bind.peerCredentialLoad(id: peerId);
      if (json.isEmpty) return null;
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      return PeerCredential.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<bool> save({
    required String peerId,
    required String accessSecret,
    String osUsername = '',
    String osSecret = '',
    String label = '',
    bool biometricRequired = true,
  }) async {
    try {
      final ok = await bind.peerCredentialSave(
        id: peerId,
        accessSecret: accessSecret,
        osUsername: osUsername,
        osSecret: osSecret,
        label: label,
        biometricRequired: biometricRequired,
      );
      if (ok && !configuredPeerIds.contains(peerId)) {
        configuredPeerIds.add(peerId);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<bool> delete(String peerId) async {
    try {
      final ok = await bind.peerCredentialDelete(id: peerId);
      if (ok) configuredPeerIds.remove(peerId);
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> markStale(String peerId) async {
    try {
      await bind.peerCredentialSetState(id: peerId, state: 'stale');
    } catch (_) {}
  }

  Future<void> touch(String peerId) async {
    try {
      await bind.peerCredentialTouch(id: peerId);
    } catch (_) {}
  }

  Future<int> recordFailure(String peerId) async {
    try {
      return await bind.peerCredentialRecordFailure(id: peerId);
    } catch (_) {
      return 0;
    }
  }
}
