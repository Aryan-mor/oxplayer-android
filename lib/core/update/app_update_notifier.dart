import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'android_package_info.dart';
import 'app_update_config.dart';
import 'github_release_service.dart';
import 'semver_utils.dart';
import 'update_prefs.dart';
import 'update_platform.dart';

/// When true, TDLib and welcome bootstrap may run.
final appUpdateGateReleasedProvider = StateProvider<bool>((ref) => false);

final githubReleaseServiceProvider = Provider<GithubReleaseService>((ref) {
  return GithubReleaseService();
});

class AppUpdatePrompt {
  const AppUpdatePrompt({
    required this.mandatory,
    required this.currentVersion,
    required this.releaseTag,
    required this.downloadUrl,
    required this.fallbackUrl,
  });

  final bool mandatory;
  final String currentVersion;
  final String releaseTag;
  final String? downloadUrl;
  final String fallbackUrl;
}

class AppUpdateNotifier extends Notifier<AppUpdatePrompt?> {
  Completer<void>? _releaseCompleter;

  @override
  AppUpdatePrompt? build() => null;

  /// Blocks until the user may proceed (no update, dismissed optional, or error).
  Future<void> waitUntilGateReleased() async {
    if (ref.read(appUpdateGateReleasedProvider)) return;
    _releaseCompleter ??= Completer<void>();
    return _releaseCompleter!.future;
  }

  void _releaseGate() {
    if (ref.read(appUpdateGateReleasedProvider)) return;
    ref.read(appUpdateGateReleasedProvider.notifier).state = true;
    if (!(_releaseCompleter?.isCompleted ?? true)) {
      _releaseCompleter!.complete();
    }
  }

  Future<void> runStartupCheck() async {
    if (kIsWeb || !runsAndroidUpdateCheck || kDebugMode) {
      _releaseGate();
      return;
    }

    GithubReleaseInfo? info;
    try {
      info = await ref.read(githubReleaseServiceProvider).fetchLatest();
    } catch (_) {
      info = null;
    }

    if (info == null) {
      _releaseGate();
      return;
    }

    final versionName = await readAndroidPackageVersionName();
    final local =
        versionName != null ? tryParsePackageVersionName(versionName) : null;
    final remote = tryParseSemVer(info.tagName);
    if (local == null || remote == null) {
      _releaseGate();
      return;
    }

    if (!isRemoteNewer(local, remote)) {
      _releaseGate();
      return;
    }

    final skipped = await readSkippedReleaseTag();
    if (skipped != null && skipped == info.tagName) {
      _releaseGate();
      return;
    }

    final mandatory = isMandatorySemverBump(
      local: local,
      remote: remote,
      patchOptional: kPatchOnlyUpdatesAreOptional,
    );

    state = AppUpdatePrompt(
      mandatory: mandatory,
      currentVersion: versionName ?? 'unknown',
      releaseTag: info.tagName,
      downloadUrl: info.downloadUrl,
      fallbackUrl: info.fallbackReleasesUrl,
    );
    if (!mandatory) {
      return;
    }
  }

  /// After optional flow: user tapped Download and the browser was opened.
  void clearOptionalAfterDownload() {
    state = null;
    _releaseGate();
  }

  void skipThisVersion(AppUpdatePrompt p) {
    unawaited(writeSkippedReleaseTag(p.releaseTag));
    state = null;
    _releaseGate();
  }

  void closeOptional() {
    state = null;
    _releaseGate();
  }
}

final appUpdateNotifierProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdatePrompt?>(
  AppUpdateNotifier.new,
);
