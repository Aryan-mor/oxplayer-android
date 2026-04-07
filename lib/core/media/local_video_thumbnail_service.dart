import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../data/models/app_media.dart';
import '../../telegram/media_file_locator_resolver.dart';
import '../../telegram/tdlib_facade.dart';
import '../debug/app_debug_log.dart';

const _kNegKey = 'local_video_thumb_negative_v1';
const _kCacheSubdir = 'local_video_posters';
const _kMinVideoPrefixBytes = 768 * 1024;
const _kMaxTdlibDownloadLimit = 4 * 1024 * 1024;
const _kPrefixWait = Duration(seconds: 26);
const _kPollInterval = Duration(milliseconds: 380);

void _thumbLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

/// When the API has no poster, extracts a JPEG from the Telegram-backed video file,
/// caches it on disk, and remembers definitive failures so we do not retry forever.
class LocalVideoThumbnailService {
  LocalVideoThumbnailService._();
  static final LocalVideoThumbnailService instance = LocalVideoThumbnailService._();

  final Map<String, Future<File?>> _inFlight = {};
  Future<void>? _negLoaded;
  Set<String> _negativeIds = {};

  Future<void> ensureNegativeLoaded() async {
    _negLoaded ??= _loadNegative();
    await _negLoaded;
  }

  bool isNegative(String mediaId) => _negativeIds.contains(mediaId);

  Future<void> _loadNegative() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kNegKey);
      if (raw == null || raw.isEmpty) {
        _negativeIds = {};
        return;
      }
      final list = jsonDecode(raw);
      if (list is List) {
        _negativeIds = list.map((e) => e.toString()).toSet();
      }
    } catch (_) {
      _negativeIds = {};
    }
  }

  Future<void> _persistNegative() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kNegKey, jsonEncode(_negativeIds.toList()));
    } catch (_) {}
  }

  Future<void> _addNegative(String mediaId) async {
    _negativeIds.add(mediaId);
    await _persistNegative();
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, _kCacheSubdir));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _cacheFileName(String mediaId) {
    final enc = base64Url.encode(utf8.encode(mediaId)).replaceAll('=', '');
    return '$enc.jpg';
  }

  Future<File?> _existingCacheFile(String mediaId) async {
    final dir = await _cacheDir();
    final f = File(p.join(dir.path, _cacheFileName(mediaId)));
    if (await f.exists()) {
      final len = await f.length();
      if (len > 32) return f;
    }
    return null;
  }

  /// Picks a file row likely to resolve in Telegram (streamable first).
  AppMediaFile? pickPrimaryFile(List<AppMediaFile> files) {
    if (files.isEmpty) return null;
    bool hasLocator(AppMediaFile f) {
      if ((f.telegramFileId ?? '').trim().isNotEmpty) return true;
      if ((f.locatorRemoteFileId ?? '').trim().isNotEmpty) return true;
      final t = (f.locatorType ?? '').trim();
      if (t.isNotEmpty &&
          f.locatorChatId != null &&
          f.locatorMessageId != null) {
        return true;
      }
      return false;
    }

    final withStream = files.where((f) => f.canStream && hasLocator(f)).toList();
    if (withStream.isNotEmpty) return withStream.first;
    final withLoc = files.where(hasLocator).toList();
    if (withLoc.isNotEmpty) return withLoc.first;
    return files.first;
  }

  Future<File?> ensurePosterFile({
    required TdlibFacade tdlib,
    required String mediaId,
    required List<AppMediaFile> files,
  }) {
    final id = mediaId.trim();
    if (id.isEmpty) return Future.value(null);
    return _inFlight.putIfAbsent(
      id,
      () => _ensurePosterFileTracked(
        tdlib: tdlib,
        mediaId: id,
        files: files,
      ),
    );
  }

  Future<File?> _ensurePosterFileTracked({
    required TdlibFacade tdlib,
    required String mediaId,
    required List<AppMediaFile> files,
  }) async {
    try {
      return await _ensurePosterFileImpl(
        tdlib: tdlib,
        mediaId: mediaId,
        files: files,
      );
    } finally {
      final dropped = _inFlight.remove(mediaId);
      if (dropped != null) {
        // Same [Future] is awaited by callers; only silence the discarded map value.
        unawaited(dropped);
      }
    }
  }

  Future<File?> _ensurePosterFileImpl({
    required TdlibFacade tdlib,
    required String mediaId,
    required List<AppMediaFile> files,
  }) async {
    await ensureNegativeLoaded();
    if (_negativeIds.contains(mediaId)) return null;

    final hit = await _existingCacheFile(mediaId);
    if (hit != null) return hit;

    if (!tdlib.isInitialized) {
      _thumbLog('LocalVideoThumb: tdlib not initialized mediaId=$mediaId');
      return null;
    }

    final fileRow = pickPrimaryFile(files);
    if (fileRow == null) {
      _thumbLog('LocalVideoThumb: no file rows mediaId=$mediaId');
      return null;
    }

    final resolved = await resolveTelegramMediaFile(
      tdlib: tdlib,
      mediaFileId: fileRow.id,
      telegramFileId: fileRow.telegramFileId,
      locatorType: fileRow.locatorType,
      locatorChatId: fileRow.locatorChatId,
      locatorMessageId: fileRow.locatorMessageId,
      locatorBotUsername: fileRow.locatorBotUsername,
      locatorRemoteFileId: fileRow.locatorRemoteFileId,
      expectedFileUniqueId: fileRow.fileUniqueId,
    );
    if (resolved == null) {
      _thumbLog('LocalVideoThumb: resolve failed mediaId=$mediaId');
      return null;
    }

    final videoPath = await _waitForReadablePrefix(
      tdlib: tdlib,
      fileId: resolved.file.id,
    );
    if (videoPath == null || videoPath.isEmpty) {
      _thumbLog('LocalVideoThumb: no local prefix mediaId=$mediaId');
      return null;
    }

    final src = File(videoPath);
    if (!await src.exists()) {
      return null;
    }

    Uint8List? bytes;
    try {
      bytes = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 480,
        quality: 78,
        timeMs: 1200,
      );
    } catch (e) {
      _thumbLog('LocalVideoThumb: thumbnailData error mediaId=$mediaId $e');
    }

    if (bytes == null || bytes.isEmpty) {
      _thumbLog('LocalVideoThumb: extraction failed (negative cache) mediaId=$mediaId');
      await _addNegative(mediaId);
      return null;
    }

    final dir = await _cacheDir();
    final out = File(p.join(dir.path, _cacheFileName(mediaId)));
    try {
      await out.writeAsBytes(bytes, flush: true);
    } catch (e) {
      _thumbLog('LocalVideoThumb: write cache failed mediaId=$mediaId $e');
      return null;
    }
    return out;
  }

  Future<String?> _waitForReadablePrefix({
    required TdlibFacade tdlib,
    required int fileId,
  }) async {
    final deadline = DateTime.now().add(_kPrefixWait);
    while (DateTime.now().isBefore(deadline)) {
      td.File? f;
      try {
        final obj = await tdlib.send(td.GetFile(fileId: fileId));
        if (obj is td.File) f = obj;
      } catch (_) {}

      if (f != null) {
        final path = f.local.path.trim();
        final downloaded = f.local.downloadedSize;
        if (path.isNotEmpty && downloaded >= _kMinVideoPrefixBytes) {
          return path;
        }
      }

      try {
        await tdlib.send(td.DownloadFile(
          fileId: fileId,
          priority: 8,
          offset: 0,
          limit: _kMaxTdlibDownloadLimit,
          synchronous: false,
        ));
      } catch (_) {}

      await Future<void>.delayed(_kPollInterval);
    }
    return null;
  }
}

