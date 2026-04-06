import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'semver_utils.dart';

const _kCachedReleaseTag = 'app_update_apk_release_tag';

/// Resolved path for the side-loaded update APK (under app external files).
Future<File> updateApkFile() async {
  final base = await getExternalStorageDirectory();
  if (base == null) {
    throw StateError('No external storage directory');
  }
  final dir = Directory(p.join(base.path, 'Downloads'));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return File(p.join(dir.path, 'oxplayer_update.apk'));
}

Future<String?> readCachedReleaseTag() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kCachedReleaseTag);
}

Future<void> writeCachedReleaseTag(String tag) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kCachedReleaseTag, tag);
}

Future<void> clearCachedReleaseTag() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kCachedReleaseTag);
}

/// Deletes the on-disk APK and clears prefs (best-effort).
Future<void> deleteCachedApkAndMetadata() async {
  await clearCachedReleaseTag();
  try {
    final f = await updateApkFile();
    if (await f.exists()) {
      await f.delete();
    }
  } catch (_) {}
}

/// Removes stale or obsolete cached APKs. Call on startup (and optionally on resume).
///
/// - No file / bad metadata → clear.
/// - Cached release is not newer than [installed] → user updated or rolled back.
/// - [latestRemote] is set and cached &lt; latest → a newer build shipped; drop old file.
Future<void> reconcileApkCache({
  required SemVer? installed,
  SemVer? latestRemote,
}) async {
  final tag = await readCachedReleaseTag();
  File file;
  try {
    file = await updateApkFile();
  } catch (_) {
    await clearCachedReleaseTag();
    return;
  }

  if (tag == null || tag.isEmpty) {
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    return;
  }

  if (!file.existsSync()) {
    await clearCachedReleaseTag();
    return;
  }

  final cachedVer = tryParseSemVer(tag);
  if (installed == null || cachedVer == null) {
    await deleteCachedApkAndMetadata();
    return;
  }

  if (SemVer.compare(cachedVer, installed) <= 0) {
    await deleteCachedApkAndMetadata();
    return;
  }

  if (latestRemote != null && SemVer.compare(cachedVer, latestRemote) < 0) {
    await deleteCachedApkAndMetadata();
  }
}

/// Returns [file.path] if the cached APK matches [releaseTag] and exists.
Future<String?> cachedApkPathForRelease(String releaseTag) async {
  final tag = await readCachedReleaseTag();
  if (tag != releaseTag) return null;
  try {
    final f = await updateApkFile();
    if (!await f.exists()) return null;
    return f.path;
  } catch (_) {
    return null;
  }
}
