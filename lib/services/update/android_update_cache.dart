import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'semver_utils.dart';

const _kCachedReleaseTag = 'app_update_apk_release_tag';

Future<File> updateApkFile() async {
  final base = await getExternalStorageDirectory();
  if (base == null) {
    throw StateError('No external storage directory available');
  }

  final downloadDir = Directory(p.join(base.path, 'Downloads'));
  if (!downloadDir.existsSync()) {
    downloadDir.createSync(recursive: true);
  }

  return File(p.join(downloadDir.path, 'oxplayer_update.apk'));
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

Future<void> deleteCachedApkAndMetadata() async {
  await clearCachedReleaseTag();
  try {
    final file = await updateApkFile();
    if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {}
}

Future<void> reconcileApkCache({
  required SemVer? installed,
  SemVer? latestRemote,
}) async {
  final tag = await readCachedReleaseTag();
  late final File file;
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

  final cachedVersion = tryParseSemVer(tag);
  if (installed == null || cachedVersion == null) {
    await deleteCachedApkAndMetadata();
    return;
  }

  if (SemVer.compare(cachedVersion, installed) <= 0) {
    await deleteCachedApkAndMetadata();
    return;
  }

  if (latestRemote != null && SemVer.compare(cachedVersion, latestRemote) < 0) {
    await deleteCachedApkAndMetadata();
  }
}

Future<String?> cachedApkPathForRelease(String releaseTag) async {
  final cachedTag = await readCachedReleaseTag();
  if (cachedTag != releaseTag) return null;

  try {
    final file = await updateApkFile();
    if (!await file.exists()) return null;
    return file.path;
  } catch (_) {
    return null;
  }
}