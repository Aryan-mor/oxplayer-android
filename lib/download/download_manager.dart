import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib/td_api.dart' as td;

import '../core/debug/app_debug_log.dart';
import '../data/local/entities.dart';
import '../telegram/tdlib_facade.dart';

const _kDownloadPriority = 1;
const _kDownloadLimit = 0; // 0 => unlimited/chunking handled by TDLib

// ─── State ───────────────────────────────────────────────────────────────────

sealed class DownloadState {
  const DownloadState();
}

class DownloadIdle extends DownloadState {
  const DownloadIdle();
}

class Downloading extends DownloadState {
  const Downloading({
    required this.bytesDownloaded,
    required this.totalBytes,
  });
  final int bytesDownloaded;
  final int? totalBytes;

  double get progress =>
      (totalBytes != null && totalBytes! > 0)
          ? (bytesDownloaded / totalBytes!).clamp(0.0, 1.0)
          : 0.0;

  int get percent => (progress * 100).round();
}

class DownloadPaused extends DownloadState {
  const DownloadPaused({
    required this.bytesDownloaded,
    required this.totalBytes,
  });
  final int bytesDownloaded;
  final int? totalBytes;

  double get progress =>
      (totalBytes != null && totalBytes! > 0)
          ? (bytesDownloaded / totalBytes!).clamp(0.0, 1.0)
          : 0.0;

  int get percent => (progress * 100).round();
}

class DownloadCompleted extends DownloadState {
  const DownloadCompleted({required this.localFilePath});
  final String localFilePath;
}

class DownloadError extends DownloadState {
  const DownloadError({required this.message});
  final String message;
}

// ─── Manager ─────────────────────────────────────────────────────────────────

/// Manages TDLib-based downloads for a single [globalId] at a time.
///
/// One [DownloadManager] instance is typically kept alive by a Riverpod provider.
/// It subscribes to [TdlibFacade.updates()] to track [updateFile] progress.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required TdlibFacade tdlib,
    required Isar isar,
  })  : _tdlib = tdlib,
        _isar = isar {
    _updateSub = tdlib.updates().listen(_onTdlibUpdate);
  }

  final TdlibFacade _tdlib;
  final Isar _isar;
  StreamSubscription<Map<String, dynamic>>? _updateSub;

  /// Per-globalId download state. Widgets read this to render button state.
  final Map<String, DownloadState> _states = {};

  /// Maps active TDLib file IDs → globalId so [_onTdlibUpdate] can route events.
  final Map<int, String> _fileIdToGlobalId = {};

  DownloadState stateFor(String globalId) =>
      _states[globalId] ?? const DownloadIdle();

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Restores persisted download states (completed/paused) after app restart.
  Future<void> restorePersistedStates() async {
    final rows = await _isar.mediaDownloads.where().findAll();
    if (rows.isEmpty) return;

    var changed = false;
    for (final row in rows) {
      if (row.status == 'completed') {
        final path = row.localFilePath;
        if (path != null && await File(path).exists()) {
          _states[row.globalId] = DownloadCompleted(localFilePath: path);
          changed = true;
        }
      } else if (row.status == 'paused') {
        _states[row.globalId] = DownloadPaused(
          bytesDownloaded: row.bytesDownloaded,
          totalBytes: row.totalBytes,
        );
        changed = true;
      } else if (row.status == 'downloading') {
        // On cold start, in-flight downloads should be shown as resumable.
        _states[row.globalId] = DownloadPaused(
          bytesDownloaded: row.bytesDownloaded,
          totalBytes: row.totalBytes,
        );
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  /// Checks disk + db for an existing completed download.
  /// Returns the local path if the file actually exists on disk, `null` otherwise.
  /// Call this to decide whether to show Play or Download on page load.
  Future<String?> checkExistingFile(String globalId) async {
    final completedRows = await _isar.mediaDownloads
        .filter()
        .globalIdEqualTo(globalId)
        .statusEqualTo('completed')
        .findAll();

    for (final row in completedRows) {
      final path = row.localFilePath;
      if (path != null && await File(path).exists()) {
        _setState(globalId, DownloadCompleted(localFilePath: path));
        return path;
      }
    }

    final pausedRow = await _isar.mediaDownloads
        .filter()
        .globalIdEqualTo(globalId)
        .statusEqualTo('paused')
        .findFirst();
    if (pausedRow != null) {
      _setState(
        globalId,
        DownloadPaused(
          bytesDownloaded: pausedRow.bytesDownloaded,
          totalBytes: pausedRow.totalBytes,
        ),
      );
      return null;
    }
    // File missing — ensure state is Idle
    _setState(globalId, const DownloadIdle());
    return null;
  }

  /// Starts a TDLib download.
  ///
  /// [variantId] / [msgId] / [chatId] tell us which [MediaVariant] to pull.
  /// [title] and [year] are used to compute the standardized file name.
  Future<void> startDownload({
    required String globalId,
    required String variantId,
    required int msgId,
    required int chatId,
    required String title,
    required String year,
    String? mimeType,
    int? fileSize,
  }) async {
    if (_states[globalId] is Downloading) return; // already running

    AppDebugLog.instance.log(
      'DownloadManager: startDownload globalId=$globalId variantId=$variantId',
    );

    _setState(globalId, const Downloading(bytesDownloaded: 0, totalBytes: null));

    try {
      // 1. Get the TDLib message to obtain the file object
      final msgObj =
          await _tdlib.send(td.GetMessage(chatId: chatId, messageId: msgId));
      if (msgObj is! td.Message) {
        throw Exception('Could not retrieve message $msgId from chat $chatId');
      }

      td.File? tdFile;
      if (msgObj.content is td.MessageVideo) {
        tdFile = (msgObj.content as td.MessageVideo).video.video;
      } else if (msgObj.content is td.MessageDocument) {
        tdFile = (msgObj.content as td.MessageDocument).document.document;
      }

      // Backward compatibility: old indexed rows may point to a metadata text
      // message that replies to the actual media message.
      if (tdFile == null && msgObj.replyTo is td.MessageReplyToMessage) {
        final replyToId = (msgObj.replyTo as td.MessageReplyToMessage).messageId;
        final repliedObj =
            await _tdlib.send(td.GetMessage(chatId: chatId, messageId: replyToId));
        if (repliedObj is td.Message) {
          if (repliedObj.content is td.MessageVideo) {
            tdFile = (repliedObj.content as td.MessageVideo).video.video;
          } else if (repliedObj.content is td.MessageDocument) {
            tdFile = (repliedObj.content as td.MessageDocument).document.document;
          }
        }
      }
      if (tdFile == null) {
        throw Exception('Message has no downloadable file');
      }

      final ext = _extensionFromMime(mimeType) ??
          _extensionFromFileName(tdFile.local.path) ??
          'mkv';
      final standardizedName = _buildStandardizedName(title, year, ext);

      // 2. Upsert the MediaDownload row
      final downloadId = '$globalId:$variantId';
      final now = DateTime.now().millisecondsSinceEpoch;
      final row = MediaDownload()
        ..downloadId = downloadId
        ..globalId = globalId
        ..variantId = variantId
        ..fileName = standardizedName
        ..status = 'downloading'
        ..bytesDownloaded = tdFile.local.downloadedSize
        ..totalBytes = fileSize ?? (tdFile.expectedSize > 0 ? tdFile.expectedSize : null)
        ..updatedAt = now
        ..mimeType = mimeType
        ..standardizedName = standardizedName
        ..tdlibFileId = tdFile.id;

      await _isar.writeTxn(() => _isar.mediaDownloads.put(row));

      _fileIdToGlobalId[tdFile.id] = globalId;

      // 3. Kick off the TDLib download
      AppDebugLog.instance.log(
        'DownloadManager: td.DownloadFile tuning before/after: '
        'priority: default/legacy(3) -> $_kDownloadPriority, '
        'limit: default -> $_kDownloadLimit',
      );
      await _tdlib.send(td.DownloadFile(
        fileId: tdFile.id,
        priority: _kDownloadPriority,
        offset: 0,
        limit: _kDownloadLimit,
        synchronous: false,
      ));
    } catch (e, st) {
      AppDebugLog.instance.log('DownloadManager: startDownload error: $e');
      debugPrint('DownloadManager: startDownload: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
  }

  /// Pause an active TDLib download while preserving partial progress.
  Future<void> pauseDownload(String globalId) async {
    final rows = await _isar.mediaDownloads
        .filter()
        .globalIdEqualTo(globalId)
        .findAll();
    if (rows.isEmpty) return;

    final row = rows.firstWhere(
      (r) => r.status == 'downloading' && r.tdlibFileId != null,
      orElse: () => rows.first,
    );
    final fileId = row.tdlibFileId;
    if (fileId == null) return;

    try {
      await _tdlib.send(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false));
      final now = DateTime.now().millisecondsSinceEpoch;
      await _isar.writeTxn(() async {
        row
          ..status = 'paused'
          ..updatedAt = now;
        await _isar.mediaDownloads.put(row);
      });
      _setState(
        globalId,
        DownloadPaused(
          bytesDownloaded: row.bytesDownloaded,
          totalBytes: row.totalBytes,
        ),
      );
    } catch (e, st) {
      AppDebugLog.instance.log('DownloadManager: pauseDownload error: $e');
      debugPrint('DownloadManager: pauseDownload: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
  }

  /// Resume a previously paused download.
  Future<void> resumeDownload(String globalId) async {
    final row = await _isar.mediaDownloads
        .filter()
        .globalIdEqualTo(globalId)
        .statusEqualTo('paused')
        .findFirst();
    if (row == null || row.tdlibFileId == null) {
      _setState(globalId, const DownloadIdle());
      return;
    }

    try {
      _fileIdToGlobalId[row.tdlibFileId!] = globalId;
      await _tdlib.send(td.DownloadFile(
        fileId: row.tdlibFileId!,
        priority: _kDownloadPriority,
        offset: 0,
        limit: _kDownloadLimit,
        synchronous: false,
      ));

      final now = DateTime.now().millisecondsSinceEpoch;
      await _isar.writeTxn(() async {
        row
          ..status = 'downloading'
          ..updatedAt = now;
        await _isar.mediaDownloads.put(row);
      });

      _setState(
        globalId,
        Downloading(
          bytesDownloaded: row.bytesDownloaded,
          totalBytes: row.totalBytes,
        ),
      );
    } catch (e, st) {
      AppDebugLog.instance.log('DownloadManager: resumeDownload error: $e');
      debugPrint('DownloadManager: resumeDownload: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
  }

  /// Deletes the local file and clears the DB row; reverts UI to Idle.
  Future<void> deleteDownload(String globalId) async {
    AppDebugLog.instance.log('DownloadManager: deleteDownload $globalId');
    final rows = await _isar.mediaDownloads
        .filter()
        .globalIdEqualTo(globalId)
        .findAll();

    for (final row in rows) {
      final path = row.localFilePath;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      if (row.tdlibFileId != null) {
        _fileIdToGlobalId.remove(row.tdlibFileId);
        try {
          await _tdlib.send(td.CancelDownloadFile(
            fileId: row.tdlibFileId!,
            onlyIfPending: false,
          ));
        } catch (_) {}
      }
    }

    await _isar.writeTxn(() async {
      for (final row in rows) {
        await _isar.mediaDownloads.delete(row.id);
      }
    });

    _setState(globalId, const DownloadIdle());
  }

  // ─── Internal: TDLib update routing ────────────────────────────────────────

  void _onTdlibUpdate(Map<String, dynamic> update) {
    final type = update['@type'] as String?;
    if (type != 'updateFile') return;

    final fileMap = update['file'] as Map<String, dynamic>?;
    if (fileMap == null) return;

    final fileId = fileMap['id'] as int?;
    if (fileId == null) return;

    final globalId = _fileIdToGlobalId[fileId];
    if (globalId == null) return;

    final local = fileMap['local'] as Map<String, dynamic>?;
    if (local == null) return;

    final downloadedSize =
        _readInt(local, snake: 'downloaded_size', camel: 'downloadedSize') ?? 0;
    final isCompleted = _readBool(
          local,
          snake: 'is_downloading_completed',
          camel: 'isDownloadingCompleted',
        ) ??
        false;
    final downloadedPath = _readString(local, key: 'path') ?? '';

    if (isCompleted) {
      _onDownloadCompleted(globalId, fileId, downloadedPath);
    } else {
      final expectedSize =
          _readInt(fileMap, snake: 'expected_size', camel: 'expectedSize');
      _setState(
        globalId,
        Downloading(bytesDownloaded: downloadedSize, totalBytes: expectedSize),
      );
      _updateDbProgress(globalId, downloadedSize, expectedSize);
    }
  }

  Future<void> _onDownloadCompleted(
    String globalId,
    int fileId,
    String tdlibPath,
  ) async {
    AppDebugLog.instance.log(
      'DownloadManager: download completed globalId=$globalId path=$tdlibPath',
    );

    try {
      // Fetch the current DB row to get the standardized name
      final rows = await _isar.mediaDownloads
          .filter()
          .globalIdEqualTo(globalId)
          .findAll();
      final row = rows.firstWhere((r) => r.tdlibFileId == fileId,
          orElse: () => rows.first);

      final standardizedName = row.standardizedName ?? row.fileName;
      final destDir = await _resolveDownloadDirectory();
      final destPath = '${destDir.path}/$standardizedName';

      // Rename / copy to permanent location
      String finalPath;
      try {
        await File(tdlibPath).rename(destPath);
        finalPath = destPath;
      } catch (_) {
        // Cross-filesystem rename failed — copy + delete
        await File(tdlibPath).copy(destPath);
        await File(tdlibPath).delete();
        finalPath = destPath;
      }

      AppDebugLog.instance.log(
        'DownloadManager: renamed to $finalPath',
      );

      // Metadata injection (metadata_god / native tag writing) is intentionally
      // skipped: rewriting MP4 atoms corrupts sample tables on some containers,
      // causing audio/video desync in players like VLC.  Title is conveyed via
      // the standardized file name and intent extras at playback time.

      // Update DB row
      final now = DateTime.now().millisecondsSinceEpoch;
      await _isar.writeTxn(() async {
        final fresh = await _isar.mediaDownloads
            .filter()
            .globalIdEqualTo(globalId)
            .findFirst();
        if (fresh != null) {
          fresh
            ..status = 'completed'
            ..localFilePath = finalPath
            ..bytesDownloaded = row.totalBytes ?? fresh.bytesDownloaded
            ..updatedAt = now;
          await _isar.mediaDownloads.put(fresh);
        }
      });

      _fileIdToGlobalId.remove(fileId);
      _setState(globalId, DownloadCompleted(localFilePath: finalPath));
    } catch (e, st) {
      AppDebugLog.instance.log(
          'DownloadManager: _onDownloadCompleted error: $e');
      debugPrint('DownloadManager: _onDownloadCompleted: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
  }

  Future<void> _updateDbProgress(
      String globalId, int downloaded, int? total) async {
    try {
      final row = await _isar.mediaDownloads
          .filter()
          .globalIdEqualTo(globalId)
          .findFirst();
      if (row == null) return;
      await _isar.writeTxn(() async {
        row.bytesDownloaded = downloaded;
        if (total != null) row.totalBytes = total;
        row.updatedAt = DateTime.now().millisecondsSinceEpoch;
        await _isar.mediaDownloads.put(row);
      });
    } catch (_) {}
  }

  void _setState(String globalId, DownloadState state) {
    _states[globalId] = state;
    notifyListeners();
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  static String _buildStandardizedName(
      String title, String year, String ext) {
    // "Interstellar" + "2014" + "mkv" → "Interstellar_2014.mkv"
    final safe = title
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    final suffix = year.isNotEmpty ? '_$year' : '';
    return '$safe$suffix.$ext';
  }

  static String? _extensionFromMime(String? mime) {
    if (mime == null) return null;
    const map = {
      'video/mp4': 'mp4',
      'video/x-matroska': 'mkv',
      'video/webm': 'webm',
      'video/quicktime': 'mov',
      'video/x-msvideo': 'avi',
    };
    return map[mime.toLowerCase()];
  }

  static String? _extensionFromFileName(String? path) {
    if (path == null || path.isEmpty) return null;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot >= path.length - 1) return null;
    return path.substring(dot + 1).toLowerCase();
  }

  static Future<Directory> _resolveDownloadDirectory() async {
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) {
        final downloads = Directory('${external.path}/Downloads');
        if (!await downloads.exists()) await downloads.create(recursive: true);
        await _cleanupLegacyInternalDownloads();
        return downloads;
      }
    }

    final dir = await getApplicationDocumentsDirectory();
    final downloads = Directory('${dir.path}/downloads');
    if (!await downloads.exists()) await downloads.create(recursive: true);
    return downloads;
  }

  static Future<void> _cleanupLegacyInternalDownloads() async {
    try {
      final internal = await getApplicationDocumentsDirectory();
      final legacy = Directory('${internal.path}/downloads');
      if (await legacy.exists()) {
        await legacy.delete(recursive: true);
        AppDebugLog.instance.log(
          'DownloadManager: removed legacy internal downloads dir ${legacy.path}',
        );
      }
    } catch (e) {
      AppDebugLog.instance.log(
        'DownloadManager: legacy internal downloads cleanup skipped: $e',
      );
    }
  }

  static int? _readInt(
    Map<String, dynamic> map, {
    required String snake,
    required String camel,
  }) {
    final value = map[snake] ?? map[camel];
    return (value as num?)?.toInt();
  }

  static bool? _readBool(
    Map<String, dynamic> map, {
    required String snake,
    required String camel,
  }) {
    final value = map[snake] ?? map[camel];
    return value as bool?;
  }

  static String? _readString(
    Map<String, dynamic> map, {
    required String key,
  }) {
    final value = map[key];
    return value as String?;
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    super.dispose();
  }
}
