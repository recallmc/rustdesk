import 'dart:convert';
import 'dart:async';

import 'package:flutter_hbb/generated_bridge.dart'
    if (dart.library.html) 'package:flutter_hbb/web/bridge.dart';
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
