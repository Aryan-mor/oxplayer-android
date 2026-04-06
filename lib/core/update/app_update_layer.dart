import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../debug/app_debug_log.dart';
import '../theme/app_theme.dart';
import '../theme/oxplayer_button.dart';
import 'android_package_info.dart';
import 'apk_downloader.dart';
import 'apk_installer.dart';
import 'apk_update_cache.dart';
import 'app_update_notifier.dart';
import 'semver_utils.dart';
import 'update_platform.dart';

enum _InstallUiPhase { downloading, ready, error }

/// Runs the GitHub release check once and shows a remote-friendly update dialog.
class AppUpdateLayer extends ConsumerStatefulWidget {
  const AppUpdateLayer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppUpdateLayer> createState() => _AppUpdateLayerState();
}

class _AppUpdateLayerState extends ConsumerState<AppUpdateLayer>
    with WidgetsBindingObserver {
  String? _lastUpdateLayerLogSig;
  bool _started = false;
  late final FocusScopeNode _dialogFocusScopeNode;
  late final FocusNode _downloadButtonFocusNode;
  late final FocusNode _installFlowPrimaryFocusNode;
  String? _focusedPromptKey;

  bool _showInstallFlow = false;
  _InstallUiPhase _installPhase = _InstallUiPhase.downloading;
  int _bytesReceived = 0;
  int _bytesTotal = 0;
  String? _installFlowError;
  String? _readyApkPath;
  CancelToken? _downloadCancel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dialogFocusScopeNode = FocusScopeNode(debugLabel: 'UpdateDialogScope');
    _downloadButtonFocusNode = FocusNode(debugLabel: 'UpdateDownloadButton');
    _installFlowPrimaryFocusNode =
        FocusNode(debugLabel: 'UpdateInstallFlowPrimary');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _started) return;
      _started = true;
      unawaited(
        ref.read(appUpdateNotifierProvider.notifier).runStartupCheck(),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _downloadCancel?.cancel();
    _dialogFocusScopeNode.dispose();
    _downloadButtonFocusNode.dispose();
    _installFlowPrimaryFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_cleanupCacheAfterResume());
    }
  }

  Future<void> _cleanupCacheAfterResume() async {
    if (kIsWeb || !runsAndroidUpdateCheck || kDebugMode) return;
    final versionName = await readAndroidPackageVersionName();
    final local =
        versionName != null ? tryParsePackageVersionName(versionName) : null;
    await reconcileApkCache(installed: local, latestRemote: null);
  }

  void _resetInstallFlow() {
    _downloadCancel?.cancel();
    _downloadCancel = null;
    _showInstallFlow = false;
    _installPhase = _InstallUiPhase.downloading;
    _bytesReceived = 0;
    _bytesTotal = 0;
    _installFlowError = null;
    _readyApkPath = null;
  }

  Future<void> _beginInstallFlow(AppUpdatePrompt p) async {
    setState(() {
      _showInstallFlow = true;
      _installFlowError = null;
    });

    final existing = p.cachedApkPath;
    if (existing != null) {
      setState(() {
        _installPhase = _InstallUiPhase.ready;
        _readyApkPath = existing;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _installFlowPrimaryFocusNode.requestFocus();
      });
      return;
    }

    final url = p.downloadUrl;
    if (url == null || url.isEmpty) {
      setState(() {
        _installPhase = _InstallUiPhase.error;
        _installFlowError =
            'No direct APK asset was found on GitHub for this device.';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _installFlowPrimaryFocusNode.requestFocus();
      });
      return;
    }

    _downloadCancel = CancelToken();
    setState(() {
      _installPhase = _InstallUiPhase.downloading;
      _bytesReceived = 0;
      _bytesTotal = 0;
    });

    try {
      await downloadReleaseApk(
        url: url,
        cancelToken: _downloadCancel!,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _bytesReceived = received;
            _bytesTotal = total;
          });
        },
      );
      final path = (await updateApkFile()).path;
      await writeCachedReleaseTag(p.releaseTag);
      if (!mounted) return;
      setState(() {
        _installPhase = _InstallUiPhase.ready;
        _readyApkPath = path;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _installFlowPrimaryFocusNode.requestFocus();
      });
    } on ApkDownloadException catch (e) {
      if (e.message == 'cancelled' || !mounted) return;
      setState(() {
        _installPhase = _InstallUiPhase.error;
        _installFlowError = e.message;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _installFlowPrimaryFocusNode.requestFocus();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _installPhase = _InstallUiPhase.error;
        _installFlowError = '$e';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _installFlowPrimaryFocusNode.requestFocus();
      });
    }
  }

  Future<void> _onInstallPressed(AppUpdatePrompt p) async {
    final path = _readyApkPath;
    if (path == null) return;
    final ok = await installDownloadedApk(path);
    if (!context.mounted) return;
    if (!ok) {
      setState(() {
        _installPhase = _InstallUiPhase.error;
        _installFlowError = 'No system package installer was available.';
      });
      return;
    }
    if (!p.mandatory) {
      ref.read(appUpdateNotifierProvider.notifier).clearOptionalAfterDownload();
    }
    _resetInstallFlow();
    setState(() {});
  }

  void _onBackFromInstallFlow(AppUpdatePrompt p) {
    _downloadCancel?.cancel();
    _downloadCancel = null;
    setState(_resetInstallFlow);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dialogFocusScopeNode.requestFocus(_downloadButtonFocusNode);
    });
  }

  @override
  Widget build(BuildContext context) {
    final prompt = ref.watch(appUpdateNotifierProvider);

    if (kDebugMode) {
      final sig =
          '${prompt?.releaseTag ?? "none"}|mandatory=${prompt?.mandatory}|'
          'installFlow=$_showInstallFlow|phase=$_installPhase';
      if (sig != _lastUpdateLayerLogSig) {
        _lastUpdateLayerLogSig = sig;
        AppDebugLog.instance.log(
          'AppUpdateLayer.build: $sig (overlay dims route when prompt!=null)',
          category: AppDebugLogCategory.app,
        );
      }
    }

    if (prompt == null && (_showInstallFlow || _installPhase != _InstallUiPhase.downloading)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(appUpdateNotifierProvider) != null) return;
        setState(_resetInstallFlow);
      });
    }

    if (prompt == null) {
      _focusedPromptKey = null;
    } else {
      final promptKey = '${prompt.releaseTag}:${prompt.mandatory}';
      if (_focusedPromptKey != promptKey) {
        _focusedPromptKey = promptKey;
        if (!_showInstallFlow) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _dialogFocusScopeNode.requestFocus(_downloadButtonFocusNode);
          });
        }
      }
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(excluding: prompt != null, child: widget.child),
        if (prompt != null)
          ModalBarrier(
            color: Colors.black.withValues(alpha: 0.72),
            dismissible: false,
          ),
        if (prompt != null)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: FocusScope(
                    node: _dialogFocusScopeNode,
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: _showInstallFlow
                          ? _buildInstallFlow(prompt)
                          : _buildPrompt(prompt),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPrompt(AppUpdatePrompt prompt) {
    final hasCached = prompt.cachedApkPath != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          prompt.mandatory ? 'Update required' : 'Update available',
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          prompt.mandatory
              ? 'This version of OXPlayer is no longer supported. '
                  'The service or app protocol has changed, so you '
                  'must download and install the new build for your '
                  'device before you can continue.'
              : 'A newer release (${prompt.releaseTag}) is available. '
                  'You are on ${prompt.currentVersion}.',
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 16,
            height: 1.45,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        FocusTraversalOrder(
          order: const NumericFocusOrder(0),
          child: OxplayerButton(
            focusNode: _downloadButtonFocusNode,
            autofocus: true,
            onPressed: () => unawaited(_beginInstallFlow(prompt)),
            child: Text(hasCached ? 'Install' : 'Download'),
          ),
        ),
        if (!prompt.mandatory) ...[
          const SizedBox(height: 14),
          FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: OxplayerButton(
              onPressed: () {
                ref.read(appUpdateNotifierProvider.notifier).skipThisVersion(prompt);
              },
              child: const Text('Skip this version'),
            ),
          ),
          const SizedBox(height: 14),
          FocusTraversalOrder(
            order: const NumericFocusOrder(2),
            child: OxplayerButton(
              onPressed: () {
                ref.read(appUpdateNotifierProvider.notifier).closeOptional();
              },
              child: const Text('Close'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildInstallFlow(AppUpdatePrompt prompt) {
    switch (_installPhase) {
      case _InstallUiPhase.downloading:
        return _buildDownloadingColumn(prompt);
      case _InstallUiPhase.ready:
        return _buildReadyColumn(prompt);
      case _InstallUiPhase.error:
        return _buildErrorColumn(prompt);
    }
  }

  Widget _buildDownloadingColumn(AppUpdatePrompt prompt) {
    final total = _bytesTotal <= 0 ? 1 : _bytesTotal;
    final progress = (_bytesReceived / total).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Downloading',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 10,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '${(progress * 100).round()}%',
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 18,
          ),
          textAlign: TextAlign.center,
        ),
        if (!prompt.mandatory) ...[
          const SizedBox(height: 24),
          OxplayerButton(
            focusNode: _installFlowPrimaryFocusNode,
            onPressed: () => _onBackFromInstallFlow(prompt),
            child: const Text('Back'),
          ),
        ],
      ],
    );
  }

  Widget _buildReadyColumn(AppUpdatePrompt prompt) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Download complete',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        const Text(
          'Use the button below to install the new version.',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 16,
            height: 1.45,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        FocusTraversalOrder(
          order: const NumericFocusOrder(0),
          child: OxplayerButton(
            focusNode: _installFlowPrimaryFocusNode,
            autofocus: true,
            onPressed: () => unawaited(_onInstallPressed(prompt)),
            child: const Text('Install'),
          ),
        ),
        if (!prompt.mandatory) ...[
          const SizedBox(height: 14),
          FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: OxplayerButton(
              onPressed: () => _onBackFromInstallFlow(prompt),
              child: const Text('Back'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildErrorColumn(AppUpdatePrompt prompt) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Error',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          _installFlowError ?? 'Unknown',
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 15,
            height: 1.45,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        FocusTraversalOrder(
          order: const NumericFocusOrder(0),
          child: OxplayerButton(
            focusNode: _installFlowPrimaryFocusNode,
            autofocus: true,
            onPressed: () => unawaited(_beginInstallFlow(prompt)),
            child: const Text('Retry'),
          ),
        ),
        if (!prompt.mandatory) ...[
          const SizedBox(height: 14),
          FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: OxplayerButton(
              onPressed: () => _onBackFromInstallFlow(prompt),
              child: const Text('Back'),
            ),
          ),
        ],
      ],
    );
  }
}
