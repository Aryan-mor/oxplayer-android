import 'dart:io';

import 'package:auto_updater/auto_updater.dart';
import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'update/android_update_cache.dart';
import 'update/android_update_downloader.dart';
import 'update/apk_installer.dart';
import 'update/github_release_service.dart';
import 'update/semver_utils.dart';

enum UpdateDeliveryKind { browser, inAppAndroid, nativeDesktop }

class UpdateInfo {
  const UpdateInfo({
    required this.deliveryKind,
    required this.releaseTag,
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    required this.releaseName,
    required this.releaseNotes,
    required this.isMandatory,
    required this.downloadUrl,
    required this.cachedApkPath,
    this.publishedAt,
  });

  final UpdateDeliveryKind deliveryKind;
  final String releaseTag;
  final String currentVersion;
  final String latestVersion;
  final String releaseUrl;
  final String releaseName;
  final String releaseNotes;
  final bool isMandatory;
  final String? downloadUrl;
  final String? cachedApkPath;
  final DateTime? publishedAt;

  bool get hasCachedApk => cachedApkPath != null && cachedApkPath!.isNotEmpty;
  bool get canDownloadInApp =>
      deliveryKind == UpdateDeliveryKind.inAppAndroid &&
      (hasCachedApk || (downloadUrl != null && downloadUrl!.isNotEmpty));

  UpdateInfo copyWith({String? cachedApkPath}) {
    return UpdateInfo(
      deliveryKind: deliveryKind,
      releaseTag: releaseTag,
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      releaseUrl: releaseUrl,
      releaseName: releaseName,
      releaseNotes: releaseNotes,
      isMandatory: isMandatory,
      downloadUrl: downloadUrl,
      cachedApkPath: cachedApkPath ?? this.cachedApkPath,
      publishedAt: publishedAt,
    );
  }
}

/// Service to check for new versions on GitHub
/// Only enabled when ENABLE_UPDATE_CHECK build flag is set
///
/// On macOS (non-Homebrew) and installed Windows: delegates to Sparkle/WinSparkle
/// via auto_updater for native update dialogs and in-app installs.
/// On Android: uses GitHub Releases + in-app APK download/install flow.
/// On all other platforms: falls back to GitHub API check + browser link dialog.
class UpdateService {
  static final Logger _logger = Logger();
  static const String _githubOwner = 'Aryan-mor';
  static const String _githubRepo = 'oxplayer-android';
  static const String _feedUrl =
      'https://cdn.jsdelivr.net/gh/$_githubOwner/$_githubRepo@appcast/appcast.xml';
  static const bool _patchOnlyUpdatesAreOptional = true;
  static final GithubReleaseService _githubReleaseService = GithubReleaseService(
    owner: _githubOwner,
    repo: _githubRepo,
  );

  // SharedPreferences keys
  static const String _keySkippedVersion = 'update_skipped_version';
  static const String _keyLastCheckTime = 'update_last_check_time';

  // Check cooldown: 6 hours
  static const Duration _checkCooldown = Duration(hours: 6);

  static bool _nativeUpdaterInitialized = false;

  /// Check if update checking is enabled via build flag
  static bool get isUpdateCheckEnabled {
    return const bool.fromEnvironment('ENABLE_UPDATE_CHECK', defaultValue: false);
  }

  /// Whether the native auto_updater (Sparkle/WinSparkle) should be used.
  /// True on macOS (non-Homebrew) and installed Windows (has uninstaller).
  static bool get useNativeUpdater {
    if (!isUpdateCheckEnabled) return false;
    if (Platform.isMacOS) return !_isHomebrewInstall();
    if (Platform.isWindows) return _isInstalledApp() && !_isWingetInstall();
    return false;
  }

  static bool get useInAppAndroidUpdater {
    return isUpdateCheckEnabled && Platform.isAndroid;
  }

  /// Initialize the native auto_updater (Sparkle/WinSparkle).
  /// Call once at startup if [useNativeUpdater] is true.
  static Future<void> initNativeUpdater() async {
    if (_nativeUpdaterInitialized) return;

    try {
      await autoUpdater.setFeedURL(_feedUrl);
      _nativeUpdaterInitialized = true;
    } catch (e) {
      _logger.e('Failed to initialize native auto updater: $e');
    }
  }

  /// Trigger a background update check via Sparkle/WinSparkle.
  /// Only shows UI if an update is found.
  static Future<void> checkForUpdatesNative({bool inBackground = true}) async {
    if (!_nativeUpdaterInitialized) {
      await initNativeUpdater();
      if (!_nativeUpdaterInitialized) return;
    }
    try {
      await autoUpdater.checkForUpdates(inBackground: inBackground);
    } catch (e) {
      _logger.e('Native update check failed: $e');
    }
  }

  /// Check if the macOS app was installed via Homebrew.
  /// Homebrew casks live under /opt/homebrew/Caskroom/ or /usr/local/Caskroom/.
  static bool _isHomebrewInstall() {
    try {
      final execPath = Platform.resolvedExecutable;
      return execPath.contains('/Caskroom/') || execPath.contains('/homebrew/');
    } catch (_) {
      return false;
    }
  }

  /// Check if the Windows app was installed via winget.
  /// The Inno Setup installer writes a .winget marker file when invoked with /WINGET=1.
  static bool _isWingetInstall() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return File('$exeDir\\.winget').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Check if the Windows app is an installed copy (not portable).
  /// The Inno Setup installer places unins000.exe next to the executable.
  static bool _isInstalledApp() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return File('$exeDir\\unins000.exe').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Skip a specific version
  static Future<void> skipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySkippedVersion, version);
  }

  /// Get the skipped version
  static Future<String?> getSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySkippedVersion);
  }

  /// Clear skipped version
  static Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySkippedVersion);
  }

  /// Check if cooldown period has passed since last check
  static Future<bool> shouldCheckForUpdates() async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheckString = prefs.getString(_keyLastCheckTime);

    if (lastCheckString == null) return true;

    final lastCheck = DateTime.parse(lastCheckString);
    final now = DateTime.now();
    final timeSinceLastCheck = now.difference(lastCheck);

    return timeSinceLastCheck >= _checkCooldown;
  }

  /// Update the last check timestamp
  static Future<void> _updateLastCheckTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastCheckTime, DateTime.now().toIso8601String());
  }

  static bool _isNewerVersion(String newVersion, String currentVersion) {
    List<int> parse(String version) {
      return version.split('.').map((part) {
        final numericPart = part.split('+').first.split('-').first;
        return int.tryParse(numericPart) ?? 0;
      }).toList();
    }

    try {
      final newParts = parse(newVersion);
      final currentParts = parse(currentVersion);
      final maxLength = newParts.length > currentParts.length
          ? newParts.length
          : currentParts.length;
      for (var index = 0; index < maxLength; index++) {
        final newPart = index < newParts.length ? newParts[index] : 0;
        final currentPart = index < currentParts.length ? currentParts[index] : 0;
        if (newPart > currentPart) return true;
        if (newPart < currentPart) return false;
      }
      return false;
    } catch (error) {
      _logger.e('Error comparing versions: $error');
      return false;
    }
  }

  static UpdateInfo _buildUpdateInfo({
    required GithubReleaseInfo release,
    required String currentVersion,
    required String cleanVersion,
    required String? cachedApkPath,
    required bool isMandatory,
  }) {
    return UpdateInfo(
      deliveryKind: useNativeUpdater
          ? UpdateDeliveryKind.nativeDesktop
          : (useInAppAndroidUpdater ? UpdateDeliveryKind.inAppAndroid : UpdateDeliveryKind.browser),
      releaseTag: release.tagName,
      currentVersion: currentVersion,
      latestVersion: cleanVersion,
      releaseUrl: release.releaseUrl,
      releaseName: release.releaseName,
      releaseNotes: release.releaseNotes,
      isMandatory: isMandatory,
      downloadUrl: release.downloadUrl,
      cachedApkPath: cachedApkPath,
      publishedAt: release.publishedAt == null ? null : DateTime.tryParse(release.publishedAt!),
    );
  }

  /// Fetch the latest GitHub release metadata without comparing versions.
  /// This is used for preview flows that need real release tag/version/download data.
  static Future<UpdateInfo?> fetchLatestReleaseInfo() async {
    if (!isUpdateCheckEnabled) {
      return null;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final release = await _githubReleaseService.fetchLatest(
        includePreferredApk: useInAppAndroidUpdater,
      );
      if (release == null) {
        return null;
      }

      final currentSemver = tryParsePackageVersionName(currentVersion);
      final latestSemver = tryParseSemVer(release.tagName);
      final cleanVersion = release.tagName.startsWith('v')
          ? release.tagName.substring(1)
          : release.tagName;
      final cachedApkPath = useInAppAndroidUpdater
          ? await cachedApkPathForRelease(release.tagName)
          : null;
      final isMandatory = currentSemver != null && latestSemver != null
          ? isMandatorySemverBump(
              local: currentSemver,
              remote: latestSemver,
              patchOptional: _patchOnlyUpdatesAreOptional,
            )
          : false;

      return _buildUpdateInfo(
        release: release,
        currentVersion: currentVersion,
        cleanVersion: cleanVersion,
        cachedApkPath: cachedApkPath,
        isMandatory: isMandatory,
      );
    } catch (error) {
      _logger.e('Failed to load latest release info: $error');
      return null;
    }
  }

  static Future<UpdateInfo?> _performUpdateCheck({required bool respectCooldown}) async {
    if (!isUpdateCheckEnabled) {
      return null;
    }

    if (respectCooldown && !await shouldCheckForUpdates()) {
      return null;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final release = await _githubReleaseService.fetchLatest(
        includePreferredApk: useInAppAndroidUpdater,
      );

      final currentSemver = tryParsePackageVersionName(currentVersion);
      final latestSemver = release != null ? tryParseSemVer(release.tagName) : null;
      if (useInAppAndroidUpdater) {
        await reconcileApkCache(installed: currentSemver, latestRemote: latestSemver);
      }

      if (release == null) {
        if (respectCooldown) {
          await _updateLastCheckTime();
        }
        return null;
      }

      final cleanVersion = release.tagName.startsWith('v')
          ? release.tagName.substring(1)
          : release.tagName;
      var hasUpdate = currentSemver != null && latestSemver != null
          ? isRemoteNewer(currentSemver, latestSemver)
          : _isNewerVersion(cleanVersion, currentVersion);

      // Package name vs release tag can differ only by `v` or `+buildNumber`; treat as same.
      if (hasUpdate &&
          normalizeComparableVersionCore(currentVersion) ==
              normalizeComparableVersionCore(cleanVersion)) {
        hasUpdate = false;
      }

      if (!hasUpdate) {
        if (respectCooldown) {
          await _updateLastCheckTime();
        }
        return null;
      }

      final skippedVersion = await getSkippedVersion();
      if (skippedVersion != null &&
          normalizeComparableVersionCore(skippedVersion) ==
              normalizeComparableVersionCore(cleanVersion)) {
        if (respectCooldown) {
          await _updateLastCheckTime();
        }
        return null;
      }

      if (respectCooldown) {
        await _updateLastCheckTime();
      }

      final cachedApkPath = useInAppAndroidUpdater
          ? await cachedApkPathForRelease(release.tagName)
          : null;
      final isMandatory = currentSemver != null && latestSemver != null
          ? isMandatorySemverBump(
              local: currentSemver,
              remote: latestSemver,
              patchOptional: _patchOnlyUpdatesAreOptional,
            )
          : false;

      return _buildUpdateInfo(
        release: release,
        currentVersion: currentVersion,
        cleanVersion: cleanVersion,
        cachedApkPath: cachedApkPath,
        isMandatory: isMandatory,
      );
    } catch (error) {
      _logger.e('Failed to check for updates: $error');
      if (respectCooldown) {
        await _updateLastCheckTime();
      }
    }

    return null;
  }

  static Future<UpdateInfo?> checkForUpdates() {
    return _performUpdateCheck(respectCooldown: false);
  }

  static Future<UpdateInfo?> checkForUpdatesOnStartup() {
    return _performUpdateCheck(respectCooldown: true);
  }

  static Future<String> prepareInAppUpdate(
    UpdateInfo updateInfo, {
    required void Function(int received, int total) onProgress,
    required bool Function() isCancelled,
    dynamic cancelToken,
  }) async {
    if (!useInAppAndroidUpdater) {
      throw const ApkDownloadException('In-app updates are only supported on Android');
    }

    if (updateInfo.hasCachedApk) {
      return updateInfo.cachedApkPath!;
    }

    final downloadUrl = updateInfo.downloadUrl;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      throw const ApkDownloadException('No APK asset was found for this device');
    }

    final token = cancelToken is CancelToken ? cancelToken : CancelToken();
    await downloadReleaseApk(
      url: downloadUrl,
      cancelToken: token,
      onProgress: (received, total) {
        if (!isCancelled()) {
          onProgress(received, total);
        }
      },
    );
    await writeCachedReleaseTag(updateInfo.releaseTag);
    final file = await updateApkFile();
    return file.path;
  }

  static Future<bool> installInAppUpdate(String apkPath) {
    return installDownloadedApk(apkPath);
  }
}
