import 'package:flutter/material.dart';

import '../biometric_gate.dart';
import '../../common.dart';
import '../credential_store.dart';

/// Configure the saved credential of one peer from the peer list.
///
/// Deliberately never fills the access-password field from an existing record: the only state the
/// UI exposes is "already configured (updated at ...)" plus replace / delete.
Future<void> showCredentialDialog(String peerId, {String? hostName}) async {
  final existing = await CredentialStore.instance.read(peerId);
  final accessController = TextEditingController();
  final confirmController = TextEditingController();
  final labelController = TextEditingController(text: existing?.label ?? '');
  final osUserController = TextEditingController(text: existing?.osUsername ?? '');
  final osPassController = TextEditingController();
  bool biometricRequired = existing?.biometricRequired ?? true;
  String? errorText;

  gFFI.dialogManager.show((setState, close, context) {
    Future<void> submit() async {
      final password = accessController.text;
      if (password.isEmpty) {
        setState(() => errorText = 'Password is required');
        return;
      }
      if (password != confirmController.text) {
        setState(() => errorText = 'Passwords do not match');
        return;
      }
      final ok = await CredentialStore.instance.save(
        peerId: peerId,
        accessSecret: password,
        osUsername: osUserController.text.trim(),
        osSecret: osPassController.text,
        label: labelController.text.trim(),
        biometricRequired: biometricRequired,
      );
      // Clear the in-memory copies as soon as the encrypted store has accepted them.
      accessController.clear();
      confirmController.clear();
      osPassController.clear();
      if (!ok) {
        setState(() => errorText = 'Could not save. Please try again.');
        return;
      }
      close();
      showToast('Saved. Tap this computer to sign in.');
    }

    return CustomAlertDialog(
      title: Text(existing == null
          ? 'Save login password'
          : 'Saved login password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hostName != null && hostName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(hostName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            if (existing != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Already configured. The password is stored encrypted and cannot be viewed.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface
                          .withOpacity(0.7)),
                ),
              ),
            TextField(
              controller: accessController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'RustDesk access password',
              ),
            ),
            TextField(
              controller: confirmController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: labelController,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            const SizedBox(height: 16),
            const Text('Optional: Windows sign-in credentials'),
            TextField(
              controller: osUserController,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Windows username'),
            ),
            TextField(
              controller: osPassController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Windows password'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: biometricRequired,
                  onChanged: (v) =>
                      setState(() => biometricRequired = v ?? true),
                ),
                const Expanded(
                  child: Text('Require fingerprint before sign in'),
                ),
              ],
            ),
            if (errorText != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(errorText!,
                    style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
      actions: [
        dialogButton('Cancel', onPressed: close, isOutline: true),
        if (existing != null)
          dialogButton(
            'Delete',
            isOutline: true,
            onPressed: () async {
              await CredentialStore.instance.delete(peerId);
              close();
              showToast('Saved password removed');
            },
          ),
        dialogButton(existing == null ? 'Save' : 'Replace',
            onPressed: submit),
      ],
    );
  });
}
