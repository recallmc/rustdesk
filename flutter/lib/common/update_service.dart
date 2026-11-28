import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/platform_model.dart';

/// Outcome of a manually triggered update check.
enum UpdateCheckStatus {
  /// The running build is the newest release.
  upToDate,

  /// A newer release exists; [UpdateCheckResult.url] points at it.
  updateAvailable,

  /// The check itself failed (offline, blocked, bad response).
  failed,
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    required this.currentVersion,
    required this.latestVersion,
    required this.url,
    required this.error,
  });

  final UpdateCheckStatus status;
  final String currentVersion;
  final String latestVersion;

  /// Release page URL, empty unless [status] is [UpdateCheckStatus.updateAvailable].
  final String url;
  final String error;

  static UpdateCheckResult failed(String error) => UpdateCheckResult(
        status: UpdateCheckStatus.failed,
        currentVersion: '',
        latestVersion: '',
        url: '',
        error: error,
      );
}

/// Ask the update channel for the newest release and compare it with this build.
Future<UpdateCheckResult> checkUpdateNow() async {
  final raw = await bind.mainCheckUpdateNow();
  try {
    final data = json.decode(raw) as Map<String, dynamic>;
    final status = switch (data['status'] as String? ?? '') {
      'up_to_date' => UpdateCheckStatus.upToDate,
      'update_available' => UpdateCheckStatus.updateAvailable,
      _ => UpdateCheckStatus.failed,
    };
    return UpdateCheckResult(
      status: status,
      currentVersion: data['current_version'] as String? ?? '',
      latestVersion: data['latest_version'] as String? ?? '',
      url: data['url'] as String? ?? '',
      error: data['error'] as String? ?? '',
    );
  } catch (e) {
    return UpdateCheckResult.failed(e.toString());
  }
}

/// APK asset of [releasePageUrl] for this build's CPU architecture, or null when unknown.
///
/// Releases publish one APK per architecture under names like
/// `rustdesk-1.5.12-aarch64-signed.apk`; the architecture comes from the Rust build so no
/// Dart-side ABI table is needed.
String? apkAssetUrl(String releasePageUrl) {
  final uri = Uri.tryParse(releasePageUrl);
  if (uri == null) return null;
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments[segments.length - 2] != 'tag') return null;
  final tag = segments.last;
  if (tag.isEmpty) return null;
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  final arch = switch (bind.mainGetTargetArch()) {
    'aarch64' => 'aarch64',
    'arm' => 'armv7',
    'x86_64' => 'x86_64',
    _ => null,
  };
  if (arch == null) return null;
  final download =
      uri.replace(pathSegments: [...segments.sublist(0, segments.length - 2), 'download', tag]);
  return '$download/rustdesk-$version-$arch-signed.apk';
}

/// Downloads [url] to a temporary file, reporting progress in bytes.
///
/// [cancelled] is polled between chunks so the caller can abort a download in flight.
Future<File> downloadApk(
  String url, {
  void Function(int received, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  final dir = await getTemporaryDirectory();
  final target = File('${dir.path}/rustdesk-update.apk');
  if (await target.exists()) {
    await target.delete();
  }
  final client = http.Client();
  IOSink? sink;
  try {
    final response = await client.send(http.Request('GET', Uri.parse(url)));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    sink = target.openWrite();
    await for (final chunk in response.stream) {
      if (cancelled?.call() ?? false) {
        throw const _DownloadCancelled();
      }
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (received == 0) {
      throw Exception('Downloaded file is empty');
    }
    return target;
  } catch (e) {
    await sink?.close();
    if (await target.exists()) {
      await target.delete();
    }
    rethrow;
  } finally {
    client.close();
  }
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

/// True when the download was aborted by the caller rather than failing.
bool isDownloadCancelled(Object error) => error is _DownloadCancelled;

/// Hands a downloaded APK to the system installer (Android only).
Future<void> installApk(String path) async {
  await _androidChannel.invokeMethod('install_apk', path);
}

const _androidChannel = MethodChannel('mChannel');
