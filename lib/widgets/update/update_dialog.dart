import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../services/update_service.dart';
import '../app_icon.dart';

enum UpdateDialogResult { none, skipped, installStarted }

Future<UpdateDialogResult> showUpdateFlowDialog(
  BuildContext context,
  UpdateInfo updateInfo, {
  required bool useLaterLabel,
}) async {
  final result = await showDialog<UpdateDialogResult>(
    context: context,
    barrierDismissible: !updateInfo.isMandatory,
    builder: (dialogContext) => _UpdateFlowDialog(
      updateInfo: updateInfo,
      useLaterLabel: useLaterLabel,
    ),
  );
  return result ?? UpdateDialogResult.none;
}

enum _DialogPhase { prompt, downloading, ready, error }

class _UpdateFlowDialog extends StatefulWidget {
  const _UpdateFlowDialog({
    required this.updateInfo,
    required this.useLaterLabel,
  });

  final UpdateInfo updateInfo;
  final bool useLaterLabel;

  @override
  State<_UpdateFlowDialog> createState() => _UpdateFlowDialogState();
}

class _UpdateFlowDialogState extends State<_UpdateFlowDialog> {
  late _DialogPhase _phase;
  late UpdateInfo _updateInfo;
  String? _errorMessage;
  String? _apkPath;
  int _bytesReceived = 0;
  int _bytesTotal = 0;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _updateInfo = widget.updateInfo;
    _apkPath = widget.updateInfo.cachedApkPath;
    _phase = widget.updateInfo.hasCachedApk ? _DialogPhase.ready : _DialogPhase.prompt;
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _openReleasePage() async {
    final url = Uri.parse(_updateInfo.releaseUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _startDownload() async {
    setState(() {
      _phase = _DialogPhase.downloading;
      _errorMessage = null;
      _bytesReceived = 0;
      _bytesTotal = 0;
    });

    final token = CancelToken();
    _cancelToken = token;

    try {
      final apkPath = await UpdateService.prepareInAppUpdate(
        _updateInfo,
        cancelToken: token,
        isCancelled: () => !mounted || token.isCancelled,
        onProgress: (received, total) {
          if (!mounted || token.isCancelled) return;
          setState(() {
            _bytesReceived = received;
            _bytesTotal = total;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _apkPath = apkPath;
        _updateInfo = _updateInfo.copyWith(cachedApkPath: apkPath);
        _phase = _DialogPhase.ready;
      });
    } catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _phase = _DialogPhase.error;
        _errorMessage = '$error';
      });
    } finally {
      if (_cancelToken == token) {
        _cancelToken = null;
      }
    }
  }

  Future<void> _install() async {
    final apkPath = _apkPath;
    if (apkPath == null) return;

    final started = await UpdateService.installInAppUpdate(apkPath);
    if (!mounted) return;

    if (started) {
      Navigator.of(context).pop(UpdateDialogResult.installStarted);
      return;
    }

    setState(() {
      _phase = _DialogPhase.error;
      _errorMessage = 'Unable to open the Android package installer on this device.';
    });
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = _updateInfo.isMandatory
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final icon = _updateInfo.isMandatory
        ? Symbols.system_update_alt_rounded
        : Symbols.system_update_rounded;

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(child: AppIcon(icon, fill: 1, color: iconColor)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _updateInfo.isMandatory ? 'Update required' : t.update.available,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                t.update.versionAvailable(version: _updateInfo.latestVersion),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPromptBody(BuildContext context) {
    final theme = Theme.of(context);
    final bodyText = _updateInfo.isMandatory
        ? 'A newer OXPlayer build is required before you can continue. Download and install the latest Android package to keep using the app.'
        : 'A newer OXPlayer build is available. You are currently on ${_updateInfo.currentVersion}.';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(context),
        const SizedBox(height: 18),
        Text(
          bodyText,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        if (_updateInfo.releaseNotes.trim().isNotEmpty) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 160),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SingleChildScrollView(
              child: Text(
                _updateInfo.releaseNotes.trim(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDownloadingBody(BuildContext context) {
    final theme = Theme.of(context);
    final total = _bytesTotal <= 0 ? 1 : _bytesTotal;
    final progress = (_bytesReceived / total).clamp(0.0, 1.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(context),
        const SizedBox(height: 18),
        Text(
          'Downloading update package',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: progress, minHeight: 10),
        const SizedBox(height: 10),
        Text(
          '${(progress * 100).round()}%',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildReadyBody(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(context),
        const SizedBox(height: 18),
        Text(
          'Download complete',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'The Android package is ready. Continue to the system installer to finish the update.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBody(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(context),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _errorMessage ?? 'Unknown update error',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onErrorContainer,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    switch (_phase) {
      case _DialogPhase.prompt:
        return _buildPromptActions(context);
      case _DialogPhase.downloading:
        return _buildDownloadingActions(context);
      case _DialogPhase.ready:
        return _buildReadyActions(context);
      case _DialogPhase.error:
        return _buildErrorActions(context);
    }
  }

  List<Widget> _buildPromptActions(BuildContext context) {
    final actions = <Widget>[];

    if (!_updateInfo.isMandatory) {
      actions.add(
        FocusableButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(UpdateDialogResult.none),
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(UpdateDialogResult.none),
            child: Text(widget.useLaterLabel ? t.common.later : t.common.close),
          ),
        ),
      );
      actions.add(
        FocusableButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await UpdateService.skipVersion(_updateInfo.latestVersion);
            if (!mounted) return;
            navigator.pop(UpdateDialogResult.skipped);
          },
          child: TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              await UpdateService.skipVersion(_updateInfo.latestVersion);
              if (!mounted) return;
              navigator.pop(UpdateDialogResult.skipped);
            },
            child: Text(t.update.skipVersion),
          ),
        ),
      );
    }

    if (_updateInfo.canDownloadInApp) {
      actions.add(
        FocusableButton(
          onPressed: _updateInfo.hasCachedApk ? _install : _startDownload,
          child: FilledButton(
            onPressed: _updateInfo.hasCachedApk ? _install : _startDownload,
            child: Text(_updateInfo.hasCachedApk ? 'Install' : 'Download'),
          ),
        ),
      );
    } else {
      actions.add(
        FocusableButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            await _openReleasePage();
            if (!mounted) return;
            if (_updateInfo.isMandatory) return;
            navigator.pop(UpdateDialogResult.none);
          },
          child: FilledButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              await _openReleasePage();
              if (!mounted) return;
              if (_updateInfo.isMandatory) return;
              navigator.pop(UpdateDialogResult.none);
            },
            child: Text(t.update.viewRelease),
          ),
        ),
      );
    }

    return actions;
  }

  List<Widget> _buildDownloadingActions(BuildContext context) {
    if (_updateInfo.isMandatory) {
      return const <Widget>[];
    }

    return [
      FocusableButton(
        autofocus: true,
        onPressed: () {
          _cancelToken?.cancel();
          setState(() {
            _phase = _DialogPhase.prompt;
          });
        },
        child: TextButton(
          onPressed: () {
            _cancelToken?.cancel();
            setState(() {
              _phase = _DialogPhase.prompt;
            });
          },
          child: Text(t.common.back),
        ),
      ),
    ];
  }

  List<Widget> _buildReadyActions(BuildContext context) {
    final actions = <Widget>[];
    if (!_updateInfo.isMandatory) {
      actions.add(
        FocusableButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(UpdateDialogResult.none),
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(UpdateDialogResult.none),
            child: Text(widget.useLaterLabel ? t.common.later : t.common.close),
          ),
        ),
      );
    }
    actions.add(
      FocusableButton(
        onPressed: _install,
        child: FilledButton(
          onPressed: _install,
          child: const Text('Install'),
        ),
      ),
    );
    return actions;
  }

  List<Widget> _buildErrorActions(BuildContext context) {
    final actions = <Widget>[];
    if (!_updateInfo.isMandatory) {
      actions.add(
        FocusableButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(UpdateDialogResult.none),
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(UpdateDialogResult.none),
            child: Text(widget.useLaterLabel ? t.common.later : t.common.close),
          ),
        ),
      );
    }
    actions.add(
      FocusableButton(
        onPressed: _updateInfo.canDownloadInApp ? _startDownload : _openReleasePage,
        child: FilledButton(
          onPressed: _updateInfo.canDownloadInApp ? _startDownload : _openReleasePage,
          child: Text(_updateInfo.canDownloadInApp ? t.common.retry : t.update.viewRelease),
        ),
      ),
    );
    return actions;
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_phase) {
      _DialogPhase.prompt => _buildPromptBody(context),
      _DialogPhase.downloading => _buildDownloadingBody(context),
      _DialogPhase.ready => _buildReadyBody(context),
      _DialogPhase.error => _buildErrorBody(context),
    };

    return AlertDialog(
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: body,
      ),
      actions: _buildActions(context),
    );
  }
}