import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

enum BiometricOutcome { ok, cancelled, failed, unavailable }

/// Local "is it really you?" gate for using a saved credential.
///
/// This authorises the *phone*. The remote PC still performs its own password / 2FA / approval
/// check -- a fingerprint here never replaces the remote authentication factor.
class BiometricGate {
  BiometricGate._();
  static final BiometricGate instance = BiometricGate._();

  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> get isAvailable async {
    if (kIsWeb) return false;
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) return false;
    try {
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    }
  }

  Future<BiometricOutcome> verify({required String reason}) async {
    if (kIsWeb) return BiometricOutcome.unavailable;
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isMacOS &&
        !Platform.isWindows) {
      return BiometricOutcome.unavailable;
    }
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final enrolled = await _auth.getAvailableBiometrics();
      if (!canCheck || enrolled.isEmpty) return BiometricOutcome.unavailable;

      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      return ok ? BiometricOutcome.ok : BiometricOutcome.cancelled;
    } on PlatformException catch (error) {
      final code = error.code.toLowerCase();
      if (code.contains('cancel') || code.contains('abort')) {
        return BiometricOutcome.cancelled;
      }
      if (code.contains('notenrolled') ||
          code.contains('unavailable') ||
          code.contains('hardware') ||
          code.contains('not supported')) {
        return BiometricOutcome.unavailable;
      }
      return BiometricOutcome.failed;
    } catch (_) {
      return BiometricOutcome.unavailable;
    }
  }
}
