import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common.dart';
import '../update_service.dart';

/// Result dialog for the manual update check, with an in-app download for Android.
///
/// The desktop keeps its own flow (`handleUpdate`), so this dialog is only used on mobile.
Future<void> showUpdateCheckDialog(
  BuildContext context,
  UpdateCheckResult result,
) {
  if (result.status != UpdateCheckStatus.updateAvailable) {
    return showDialog(
      context: context,
      builder: (context) => _UpdateMessageDialog(result: result),
    );
  }
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpdateDownloadDialog(result: result),
  );
}

class _UpdateMessageDialog extends StatelessWidget {
  const _UpdateMessageDialog({required this.result});

  final UpdateCheckResult result;

  @override
  Widget build(BuildContext context) {
    final upToDate = result.status == UpdateCheckStatus.upToDate;
    return AlertDialog(
      title: Text(translate(upToDate ? 'Already up to date' : 'Update check failed')),
      content: Text(
        upToDate
            ? '${translate('You are running the newest version')}: ${result.currentVersion}'
            : result.error.isEmpty
                ? translate('Could not reach the update server')
                : result.error,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(translate('OK')),
        ),
      ],
    );
  }
}

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.result});

  final UpdateCheckResult result;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

enum _Phase { ready, downloading, failed, installed }

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  _Phase _phase = _Phase.ready;
  int _received = 0;
  int _total = 0;
  String _error = '';
  bool _cancelRequested = false;

  /// Asset URL for this device, or null when the architecture is unknown.
  String? get _assetUrl => apkAssetUrl(widget.result.url);

  Future<void> _startDownload() async {
    final url = _assetUrl;
    if (url == null) {
      // Unknown architecture: the release page is the only safe fallback.
      await launchUrl(Uri.parse(widget.result.url));
      return;
    }
    setState(() {
      _phase = _Phase.downloading;
      _received = 0;
      _total = 0;
      _error = '';
      _cancelRequested = false;
    });
    try {
      final file = await downloadApk(
        url,
        cancelled: () => _cancelRequested,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      await installApk(file.path);
      if (!mounted) return;
      setState(() => _phase = _Phase.installed);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e.code == 'install_permission'
            ? translate('Allow installing apps from this source, then tap retry')
            : (e.message ?? e.code);
      });
    } catch (e) {
      if (!mounted) return;
      if (isDownloadCancelled(e)) {
        setState(() => _phase = _Phase.ready);
        return;
      }
      setState(() {
        _phase = _Phase.failed;
        _error = e.toString();
      });
    }
  }

  String get _progressText {
    final percent = _total > 0 ? (_received * 100 / _total).round() : 0;
    final receivedMb = (_received / 1024 / 1024).toStringAsFixed(1);
    if (_total > 0) {
      final totalMb = (_total / 1024 / 1024).toStringAsFixed(1);
      return '$percent%  ($receivedMb / $totalMb MB)';
    }
    return '$receivedMb MB';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${translate('New version')} ${widget.result.latestVersion}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${translate('Current version')}: ${widget.result.currentVersion}'),
          const SizedBox(height: 12),
          if (_phase == _Phase.ready || _phase == _Phase.failed) ...[
            Text(
              translate('Download the installer inside the app and install it from here'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_phase == _Phase.failed) ...[
              const SizedBox(height: 8),
              Text(
                _error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
          if (_phase == _Phase.downloading) ...[
            LinearProgressIndicator(
              value: _total > 0 ? _received / _total : null,
            ),
            const SizedBox(height: 8),
            Text(_progressText),
          ],
          if (_phase == _Phase.installed) ...[
            Text(translate('The installer was opened, follow the system prompt to finish')),
          ],
        ],
      ),
      actions: [
        if (_phase == _Phase.downloading)
          TextButton(
            onPressed: () => _cancelRequested = true,
            child: Text(translate('Cancel')),
          )
        else if (_phase == _Phase.installed)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(translate('Close')),
          )
        else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(translate('Later')),
          ),
          FilledButton(
            onPressed: _startDownload,
            child: Text(
              translate(_phase == _Phase.failed ? 'Retry' : 'Download and install'),
            ),
          ),
        ],
      ],
    );
  }
}
