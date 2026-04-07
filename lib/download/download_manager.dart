import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;

import '../core/debug/app_debug_log.dart';
import '../core/storage/storage_headroom.dart';
import '../player/telegram_range_playback.dart';
import '../telegram/media_file_locator_resolver.dart';
import '../telegram/tdlib_facade.dart';

void _dmglog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.download);

const _kDownloadPriority = 1;
const _kDownloadLimit = 0; // 0 => unlimited/chunking handled by TDLib
const _kPrefsKey = 'oxplayer_downloads';
/// Large downloads on leanback devices: avoid hammering TDLib; stall detection uses tick count × interval.
const _kCompletionPollInterval = Duration(seconds: 4);
/// Inactive + not complete + byte count unchanged for this many polls → treat as stalled (leanback / OOM).
const _kStallPollTicks = 15;

class _PollStallTracker {
  int lastDownloaded = -1;
  int stagnantPolls = 0;
}

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

/// Provider backup recovery + full sync in progress.
class DownloadRecovering extends DownloadState {
  const DownloadRecovering();
}

/// Resolving which Telegram message/file to download (before [Downloading]).
class DownloadLocating extends DownloadState {
  const DownloadLocating();
}

/// Telegram file missing and backup recovery failed or exhausted.
class DownloadUnavailable extends DownloadState {
  const DownloadUnavailable();
}

/// Fresh locator row from [/me/library] after backup recovery sync.
class DownloadLocatorRefresh {
  const DownloadLocatorRefresh({
    this.telegramFileId,
    this.sourceChatId,
    this.mediaFileId,
    this.locatorType,
    this.locatorChatId,
    this.locatorMessageId,
    this.locatorBotUsername,
    this.locatorRemoteFileId,
  });

  final String? telegramFileId;
  final int? sourceChatId;
  final String? mediaFileId;
  final String? locatorType;
  final int? locatorChatId;
  final int? locatorMessageId;
  final String? locatorBotUsername;
  final String? locatorRemoteFileId;
}

// ─── Record ──────────────────────────────────────────────────────────────────

class MediaDownloadRecord {
  MediaDownloadRecord({
    required this.id,
    required this.globalId,
    required this.variantId,
    required this.fileName,
    required this.status,
    required this.bytesDownloaded,
    this.totalBytes,
    required this.updatedAt,
    this.mimeType,
    this.standardizedName,
    this.tdlibFileId,
    this.localFilePath,
    this.displayTitle,
    this.mediaTitle,
    this.releaseYear,
    this.isSeriesMedia = false,
    this.season,
    this.episode,
    this.quality,
  });

  String id;
  String globalId;
  String variantId;
  String fileName;
  String status;
  int bytesDownloaded;
  int? totalBytes;
  int updatedAt;
  String? mimeType;
  String? standardizedName;
  int? tdlibFileId;
  String? localFilePath;

  /// Full line for players / MP4 tags (e.g. `Show - S01E05` or movie title).
  String? displayTitle;
  String? mediaTitle;
  String? releaseYear;
  bool isSeriesMedia;
  int? season;
  int? episode;
  String? quality;

  factory MediaDownloadRecord.fromJson(Map<String, dynamic> json) {
    final seriesRaw = json['isSeriesMedia'];
    final isSeries = seriesRaw is bool
        ? seriesRaw
        : (seriesRaw is num ? seriesRaw != 0 : false);
    return MediaDownloadRecord(
      id: json['id'] as String,
      globalId: json['globalId'] as String,
      variantId: json['variantId'] as String,
      fileName: json['fileName'] as String,
      status: json['status'] as String,
      bytesDownloaded: json['bytesDownloaded'] as int? ?? 0,
      totalBytes: json['totalBytes'] as int?,
      updatedAt: json['updatedAt'] as int? ?? 0,
      mimeType: json['mimeType'] as String?,
      standardizedName: json['standardizedName'] as String?,
      tdlibFileId: json['tdlibFileId'] as int?,
      localFilePath: json['localFilePath'] as String?,
      displayTitle: json['displayTitle'] as String?,
      mediaTitle: json['mediaTitle'] as String?,
      releaseYear: json['releaseYear'] as String?,
      isSeriesMedia: isSeries,
      season: json['season'] as int?,
      episode: json['episode'] as int?,
      quality: json['quality'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'globalId': globalId,
        'variantId': variantId,
        'fileName': fileName,
        'status': status,
        'bytesDownloaded': bytesDownloaded,
        'totalBytes': totalBytes,
        'updatedAt': updatedAt,
        'mimeType': mimeType,
        'standardizedName': standardizedName,
        'tdlibFileId': tdlibFileId,
        'localFilePath': localFilePath,
        'displayTitle': displayTitle,
        'mediaTitle': mediaTitle,
        'releaseYear': releaseYear,
        'isSeriesMedia': isSeriesMedia,
        'season': season,
        'episode': episode,
        'quality': quality,
      };
}

/// One saved file on disk (completed download) for storage UI.
class DownloadedFileOnDevice {
  const DownloadedFileOnDevice({required this.label, required this.bytes});

  final String label;
  final int bytes;
}

/// Breakdown for “cache” vs “all” local Telegram media footprint.
class LocalMediaStorageStats {
  const LocalMediaStorageStats({
    required this.downloadedFiles,
    required this.completedBytes,
    required this.cacheBytes,
    required this.totalBytes,
  });

  final List<DownloadedFileOnDevice> downloadedFiles;
  final int completedBytes;
  final int cacheBytes;
  final int totalBytes;
}

// ─── Manager ─────────────────────────────────────────────────────────────────

/// Manages TDLib-based downloads for a single [globalId] at a time.
///
/// One [DownloadManager] instance is typically kept alive by a Riverpod provider.
/// It subscribes to [TdlibFacade.updates()] to track [updateFile] progress.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required TdlibFacade tdlib,
    Future<bool> Function(String mediaFileId)? recoverFromBackup,
    Future<void> Function()? afterBackupRecoveryRefresh,
    Future<DownloadLocatorRefresh?> Function(String globalId, String variantId)?
        reloadLocatorAfterRecovery,
  })  : _tdlib = tdlib,
        _recoverFromBackup = recoverFromBackup,
        _afterBackupRecoveryRefresh = afterBackupRecoveryRefresh,
        _reloadLocatorAfterRecovery = reloadLocatorAfterRecovery {
    _updateSub = tdlib.updates().listen(
      _onTdlibUpdate,
      onError: (Object e, StackTrace st) {
        _dmglog('DownloadManager: TDLib updates stream error: $e');
        debugPrint('DownloadManager: updates stream error: $e\n$st');
      },
    );
  }

  final TdlibFacade _tdlib;
  final Future<bool> Function(String mediaFileId)? _recoverFromBackup;
  final Future<void> Function()? _afterBackupRecoveryRefresh;
  final Future<DownloadLocatorRefresh?> Function(String globalId, String variantId)?
      _reloadLocatorAfterRecovery;
  StreamSubscription<Map<String, dynamic>>? _updateSub;

  final Map<String, DownloadState> _states = {};
  final Map<int, String> _fileIdToGlobalId = {};
  final Set<String> _unavailableGlobalIds = {};
  final Map<int, Timer> _completionPollers = {};
  final Map<int, _PollStallTracker> _pollStallTrackers = {};
  final Set<String> _finalizingCompletion = {};
  final Map<int, int> _lastProgressLogBytes = {};

  List<MediaDownloadRecord> _records = [];

  DownloadState stateFor(String globalId) => _states[globalId] ?? const DownloadIdle();

  // ─── Shared Preferences Storage ────────────────────────────────────────────

  Future<void> _loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_kPrefsKey);
    if (str != null && str.isNotEmpty) {
      try {
        final list = jsonDecode(str) as List<dynamic>;
        _records = list.map((e) => MediaDownloadRecord.fromJson(e as Map<String, dynamic>)).toList();
      } catch (e) {
        _records = [];
      }
    } else {
      _records = [];
    }
  }

  Future<void> _saveRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(_records.map((r) => r.toJson()).toList());
    await prefs.setString(_kPrefsKey, jsonStr);
  }

  MediaDownloadRecord? _getRecordForGlobalId(String globalId) {
    try {
      return _records.firstWhere((r) => r.globalId == globalId);
    } catch (_) {
      return null;
    }
  }

  /// Persisted row for this variant ([globalId] is [AppMediaFile.id]).
  MediaDownloadRecord? downloadRecordFor(String globalId) =>
      _getRecordForGlobalId(globalId);

  List<MediaDownloadRecord> getAllRecords() {
    final active = _records.toList();
    active.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return active;
  }

  /// Fast sync check for whether the storage icon should appear (no disk I/O except existsSync).
  bool hasLocalStorageFootprintQuick() {
    for (final r in _records) {
      if (r.status == 'completed') {
        final p = r.localFilePath?.trim() ?? '';
        if (p.isNotEmpty) {
          try {
            if (File(p).existsSync()) return true;
          } catch (_) {}
        }
      } else {
        if (r.bytesDownloaded > 0) return true;
        if (r.tdlibFileId != null) return true;
      }
    }
    return TelegramRangePlayback.instance.activeStreamCacheBytes > 0;
  }

  Future<LocalMediaStorageStats> queryLocalMediaStorageStats() async {
    await _loadRecords();
    final downloaded = <DownloadedFileOnDevice>[];
    var completedBytes = 0;
    for (final r in _records) {
      if (r.status != 'completed') continue;
      final p = r.localFilePath?.trim() ?? '';
      if (p.isEmpty) continue;
      try {
        final f = File(p);
        if (!await f.exists()) continue;
        final len = await f.length();
        if (len <= 0) continue;
        completedBytes += len;
        final label = (r.displayTitle ?? r.mediaTitle ?? r.fileName).trim();
        downloaded.add(DownloadedFileOnDevice(
          label: label.isEmpty ? 'Downloaded file' : label,
          bytes: len,
        ));
      } catch (_) {}
    }
    var partialBytes = 0;
    for (final r in _records) {
      if (r.status == 'completed') continue;
      partialBytes += r.bytesDownloaded;
    }
    final streamBytes = TelegramRangePlayback.instance.activeStreamCacheBytes;
    final cacheBytes = partialBytes + streamBytes;
    return LocalMediaStorageStats(
      downloadedFiles: downloaded,
      completedBytes: completedBytes,
      cacheBytes: cacheBytes,
      totalBytes: completedBytes + cacheBytes,
    );
  }

  /// Drops in-progress Telegram buffers (stream + partial TDLib files) without removing finished downloads.
  Future<void> clearTelegramTemporaryCache() async {
    await TelegramRangePlayback.instance.releaseActiveCacheIfAny(reason: 'user_clear_cache');
    var changed = false;
    for (final row in List<MediaDownloadRecord>.of(_records)) {
      if (row.status == 'completed') continue;
      var touched = false;
      final partialPath = row.localFilePath?.trim() ?? '';
      if (partialPath.isNotEmpty) {
        try {
          await File(partialPath).delete();
        } catch (_) {}
        row.localFilePath = null;
        touched = true;
      }
      if (row.tdlibFileId != null) {
        _stopCompletionPolling(row.tdlibFileId!);
        _lastProgressLogBytes.remove(row.tdlibFileId!);
        _fileIdToGlobalId.remove(row.tdlibFileId);
        try {
          await _tdlib.send(td.CancelDownloadFile(
            fileId: row.tdlibFileId!,
            onlyIfPending: false,
          ));
        } catch (_) {}
        try {
          await _tdlib.send(td.DeleteFile(fileId: row.tdlibFileId!));
        } catch (_) {}
        row.tdlibFileId = null;
        touched = true;
      }
      if (touched) {
        row.bytesDownloaded = 0;
        row.status = 'paused';
        row.updatedAt = DateTime.now().millisecondsSinceEpoch;
        changed = true;
        _setState(
          row.globalId,
          DownloadPaused(bytesDownloaded: 0, totalBytes: row.totalBytes),
        );
      }
    }
    if (changed) await _saveRecords();
    notifyListeners();
  }

  /// Deletes every persisted download row and local file, and clears temporary Telegram cache.
  Future<void> clearAllDownloadsAndCache() async {
    await TelegramRangePlayback.instance.releaseActiveCacheIfAny(reason: 'user_clear_all');
    final ids = getAllRecords().map((r) => r.globalId).toList();
    for (final id in ids) {
      await deleteDownload(id);
    }
    notifyListeners();
  }

  // ─── Public API ────────────────────────────────────────────────────────────

  Future<void> restorePersistedStates() async {
    await _loadRecords();
    if (_records.isEmpty) return;

    var changed = false;
    for (final row in _records) {
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
        _states[row.globalId] = DownloadPaused(
          bytesDownloaded: row.bytesDownloaded,
          totalBytes: row.totalBytes,
        );
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  Future<String?> checkExistingFile(String globalId) async {
    await _loadRecords();
    final row = _getRecordForGlobalId(globalId);
    if (row != null) {
      if (row.status == 'completed') {
        final path = row.localFilePath;
        if (path != null && await File(path).exists()) {
          _setState(globalId, DownloadCompleted(localFilePath: path));
          return path;
        }
      } else if (row.status == 'paused' || row.status == 'downloading') {
        _setState(
          globalId,
          DownloadPaused(
            bytesDownloaded: row.bytesDownloaded,
            totalBytes: row.totalBytes,
          ),
        );
        return null;
      }
    }
    
    _setState(globalId, const DownloadIdle());
    return null;
  }

  Future<void> startDownload({
    required String globalId,
    required String variantId,
    String? telegramFileId,
    int? sourceChatId,
    String? mediaFileId,
    String? locatorType,
    int? locatorChatId,
    int? locatorMessageId,
    String? locatorBotUsername,
    String? locatorRemoteFileId,
    String? expectedFileUniqueId,
    int? msgId,
    int? chatId,
    /// Show / movie title (base name only; no SxxExx — used for saved filename).
    required String mediaTitle,
    /// UI / player label (may include `S01E05`).
    required String displayTitle,
    /// Release year string (movie); optional for series (often show year).
    String releaseYear = '',
    bool isSeriesMedia = false,
    int? season,
    int? episode,
    String? quality,
    String? mimeType,
    int? fileSize,
    bool allowBackupRecovery = true,
    void Function(String message)? onStatus,
  }) async {
    if (_unavailableGlobalIds.contains(globalId)) {
      _setState(globalId, const DownloadUnavailable());
      return;
    }
    if (_states[globalId] is Downloading ||
        _states[globalId] is DownloadRecovering ||
        _states[globalId] is DownloadLocating) {
      return;
    }

    _dmglog(
      'DownloadManager: startDownload globalId=$globalId variantId=$variantId '
      'hasTelegramFileId=${telegramFileId != null && telegramFileId.isNotEmpty} '
      'sourceChatId=$sourceChatId mediaFileId=$mediaFileId '
      'locatorType=$locatorType locatorChatId=$locatorChatId locatorMessageId=$locatorMessageId '
      'expectedUniqueId=$expectedFileUniqueId',
    );

    _setState(globalId, const DownloadLocating());

    try {
      final mediaFileIdTrim = mediaFileId?.trim() ?? '';
      final resolvedMediaFileId =
          mediaFileIdTrim.isNotEmpty ? mediaFileIdTrim : variantId;
      final resolved = await resolveTelegramMediaFile(
        tdlib: _tdlib,
        mediaFileId: resolvedMediaFileId,
        telegramFileId: telegramFileId,
        locatorType: locatorType,
        locatorChatId: locatorChatId,
        locatorMessageId: locatorMessageId,
        locatorBotUsername: locatorBotUsername,
        locatorRemoteFileId: locatorRemoteFileId,
        expectedFileUniqueId: expectedFileUniqueId,
      );
      td.File? tdFile = resolved?.file;
      if (tdFile == null && msgId != null && msgId > 0 && chatId != null && chatId != 0) {
        try {
          final msgObj =
              await _tdlib.send(td.GetMessage(chatId: chatId, messageId: msgId));
          if (msgObj is td.Message) {
            tdFile = _extractFileFromMessage(msgObj);
          }
        } on td.TdError catch (e) {
          _dmglog(
            'DownloadManager: GetMessage(legacy msgId/chatId) failed chatId=$chatId '
            'messageId=$msgId code=${e.code} message=${e.message}',
          );
        }
      }

      if (tdFile == null) {
        throw Exception('File metadata missing; cannot identify file to download.');
      }

      final tdTotal =
          tdFile.expectedSize > 0 ? tdFile.expectedSize : (tdFile.size > 0 ? tdFile.size : null);
      var row = _getRecordForGlobalId(globalId);
      final initialTotalBytes = _mergeDownloadTotals(
        tdExpected: tdTotal,
        persistedTotal: row?.totalBytes ?? fileSize,
        downloaded: tdFile.local.downloadedSize,
      );

      _setState(
        globalId,
        Downloading(
          bytesDownloaded: tdFile.local.downloadedSize,
          totalBytes: initialTotalBytes,
        ),
      );

      final ext = _extensionFromMime(mimeType) ??
          _extensionFromFileName(tdFile.local.path) ??
          'mkv';
      final standardizedName = _buildDownloadFileName(
        mediaTitle: mediaTitle,
        releaseYear: releaseYear,
        isSeriesMedia: isSeriesMedia,
        season: season,
        episode: episode,
        quality: quality,
        ext: ext,
      );

      final downloadId = '$globalId:$variantId';
      final now = DateTime.now().millisecondsSinceEpoch;
      final initialLocalPath = tdFile.local.path.trim();
      if (row != null) {
        row.status = 'downloading';
        row.bytesDownloaded = tdFile.local.downloadedSize;
        row.totalBytes = initialTotalBytes;
        row.updatedAt = now;
        row.tdlibFileId = tdFile.id;
        row.standardizedName = standardizedName;
        row.fileName = standardizedName;
        row.displayTitle = displayTitle;
        row.mediaTitle = mediaTitle;
        row.releaseYear = releaseYear;
        row.isSeriesMedia = isSeriesMedia;
        row.season = season;
        row.episode = episode;
        row.quality = quality;
        if (initialLocalPath.isNotEmpty) {
          row.localFilePath = initialLocalPath;
        }
      } else {
        row = MediaDownloadRecord(
          id: downloadId,
          globalId: globalId,
          variantId: variantId,
          fileName: standardizedName,
          status: 'downloading',
          bytesDownloaded: tdFile.local.downloadedSize,
          totalBytes: initialTotalBytes,
          updatedAt: now,
          mimeType: mimeType,
          standardizedName: standardizedName,
          tdlibFileId: tdFile.id,
          localFilePath: initialLocalPath.isNotEmpty ? initialLocalPath : null,
          displayTitle: displayTitle,
          mediaTitle: mediaTitle,
          releaseYear: releaseYear,
          isSeriesMedia: isSeriesMedia,
          season: season,
          episode: episode,
          quality: quality,
        );
        _records.add(row);
      }
      
      await _saveRecords();
      _fileIdToGlobalId[tdFile.id] = globalId;

      await _maybeRunLowStorageCleanupBeforeTransfer(
        activeFileId: tdFile.id,
        onStatus: onStatus,
      );

      await _tdlib.send(td.DownloadFile(
        fileId: tdFile.id,
        priority: _kDownloadPriority,
        offset: 0,
        limit: _kDownloadLimit,
        synchronous: false,
      ));
      _beginCompletionPolling(globalId, tdFile.id);
    } catch (e, st) {
      _dmglog('DownloadManager: startDownload error: $e');
      debugPrint('DownloadManager: startDownload: $e\n$st');

      if (!_isMissingTelegramFileError(e)) {
        _setState(globalId, DownloadError(message: e.toString()));
        return;
      }

      if (!allowBackupRecovery) {
        _unavailableGlobalIds.add(globalId);
        _setState(globalId, const DownloadUnavailable());
        return;
      }

      if (_recoverFromBackup == null || _afterBackupRecoveryRefresh == null) {
        _setState(globalId, DownloadError(message: e.toString()));
        return;
      }

      _setState(globalId, const DownloadRecovering());
      final fid = (mediaFileId != null && mediaFileId.trim().isNotEmpty)
          ? mediaFileId.trim()
          : variantId;
      var recovered = false;
      try {
        recovered = await _recoverFromBackup(fid);
      } catch (recoverErr) {
        _dmglog(
          'DownloadManager: recoverFromBackup failed: $recoverErr',
        );
        recovered = false;
      }
      if (!recovered) {
        _unavailableGlobalIds.add(globalId);
        _setState(globalId, const DownloadUnavailable());
        return;
      }

      try {
        await _afterBackupRecoveryRefresh();
      } catch (syncErr) {
        _dmglog(
          'DownloadManager: afterBackupRecoveryRefresh: $syncErr',
        );
      }

      final fresh = await _reloadLocatorAfterRecovery?.call(globalId, variantId);
      // [startDownload] returns early while state is [DownloadRecovering]; clear it
      // so the post-recovery retry actually runs.
      _setState(globalId, const DownloadIdle());
      await startDownload(
        globalId: globalId,
        variantId: variantId,
        telegramFileId: fresh?.telegramFileId ?? telegramFileId,
        sourceChatId: fresh?.sourceChatId ?? sourceChatId,
        mediaFileId: fresh?.mediaFileId ?? mediaFileId,
        locatorType: fresh?.locatorType ?? locatorType,
        locatorChatId: fresh?.locatorChatId ?? locatorChatId,
        locatorMessageId: fresh?.locatorMessageId ?? locatorMessageId,
        locatorBotUsername: fresh?.locatorBotUsername ?? locatorBotUsername,
        locatorRemoteFileId: fresh?.locatorRemoteFileId ?? locatorRemoteFileId,
        expectedFileUniqueId: expectedFileUniqueId,
        msgId: msgId,
        chatId: chatId,
        mediaTitle: mediaTitle,
        displayTitle: displayTitle,
        releaseYear: releaseYear,
        isSeriesMedia: isSeriesMedia,
        season: season,
        episode: episode,
        quality: quality,
        mimeType: mimeType,
        fileSize: fileSize,
        allowBackupRecovery: false,
        onStatus: onStatus,
      );
    }
  }

  static bool _isMissingTelegramFileError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('file metadata missing') ||
        s.contains('cannot identify file');
  }

  Future<void> _maybeRunLowStorageCleanupBeforeTransfer({
    required int activeFileId,
    void Function(String message)? onStatus,
  }) async {
    final decision = await queryStorageCleanupDecision();
    if (!decision.cleanupMode) return;

    final freeText = decision.freeBytes == null
        ? 'unknown'
        : '${(decision.freeBytes! / (1024 * 1024)).toStringAsFixed(0)}MB';
    _dmglog('DownloadManager: low storage free=$freeText -> cleanup');
    onStatus?.call('Low storage detected. Cleaning cache...');

    final releasedStream = await TelegramRangePlayback.instance
        .releaseActiveCacheIfAny(reason: 'low_storage_download_start');
    final releasedDownloads =
        await releaseInactiveTdlibCache(keepFileId: activeFileId);
    _dmglog(
      'DownloadManager: cleanup released stream=$releasedStream downloads=$releasedDownloads',
    );

    await Future<void>.delayed(kStorageCleanupPause);
    onStatus?.call('Cache cleanup done. Starting download...');
  }

  Future<int> releaseInactiveTdlibCache({int? keepFileId}) async {
    var cleaned = 0;
    final ordered = _records.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    for (final row in ordered) {
      final fileId = row.tdlibFileId;
      if (fileId == null) continue;
      if (fileId == keepFileId) continue;
      if (row.status == 'downloading') continue;
      try {
        await _tdlib
            .send(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false));
      } catch (_) {}
      try {
        await _tdlib.send(td.DeleteFile(fileId: fileId));
        cleaned++;
      } catch (_) {}
      if (cleaned >= 3) break;
    }
    return cleaned;
  }

  td.File? _extractFileFromMessage(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.video.video;
    if (content is td.MessageDocument) return content.document.document;
    if (content is td.MessageAnimation) return content.animation.animation;
    if (content is td.MessageVideoNote) return content.videoNote.video;
    return null;
  }

  Future<void> pauseDownload(String globalId) async {
    final row = _getRecordForGlobalId(globalId);
    if (row == null || row.tdlibFileId == null || row.status != 'downloading') return;

    try {
      _stopCompletionPolling(row.tdlibFileId!);
      await _tdlib.send(td.CancelDownloadFile(fileId: row.tdlibFileId!, onlyIfPending: false));
      row.status = 'paused';
      row.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _saveRecords();
      
      _setState(
        globalId,
        DownloadPaused(
          bytesDownloaded: row.bytesDownloaded,
          totalBytes: row.totalBytes,
        ),
      );
    } catch (e, st) {
      _dmglog('DownloadManager: pauseDownload error: $e');
      debugPrint('DownloadManager: pauseDownload: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
  }

  Future<void> resumeDownload(String globalId) async {
    final row = _getRecordForGlobalId(globalId);
    if (row == null || row.tdlibFileId == null || row.status != 'paused') {
      _setState(globalId, const DownloadIdle());
      return;
    }

    try {
      await _maybeRunLowStorageCleanupBeforeTransfer(
        activeFileId: row.tdlibFileId!,
      );
      _fileIdToGlobalId[row.tdlibFileId!] = globalId;
      await _tdlib.send(td.DownloadFile(
        fileId: row.tdlibFileId!,
        priority: _kDownloadPriority,
        offset: 0,
        limit: _kDownloadLimit,
        synchronous: false,
      ));
      _beginCompletionPolling(globalId, row.tdlibFileId!);

      row.status = 'downloading';
      row.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _saveRecords();

      _setState(
        globalId,
        Downloading(
          bytesDownloaded: row.bytesDownloaded,
          totalBytes: row.totalBytes,
        ),
      );
    } catch (e, st) {
      _dmglog('DownloadManager: resumeDownload error: $e');
      debugPrint('DownloadManager: resumeDownload: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
  }

  Future<void> deleteDownload(String globalId) async {
    _dmglog('DownloadManager: deleteDownload $globalId');
    
    final row = _getRecordForGlobalId(globalId);
    if (row != null) {
      if (row.localFilePath != null) {
        try {
          await File(row.localFilePath!).delete();
        } catch (_) {}
      }
      if (row.tdlibFileId != null) {
        _stopCompletionPolling(row.tdlibFileId!);
        _lastProgressLogBytes.remove(row.tdlibFileId!);
        _fileIdToGlobalId.remove(row.tdlibFileId);
        try {
          await _tdlib.send(td.CancelDownloadFile(
            fileId: row.tdlibFileId!,
            onlyIfPending: false,
          ));
        } catch (_) {}
      }
      _records.removeWhere((r) => r.globalId == globalId);
      await _saveRecords();
    }

    _unavailableGlobalIds.remove(globalId);
    _setState(globalId, const DownloadIdle());
  }

  void _onTdlibUpdate(Map<String, dynamic> update) {
    try {
      _onTdlibUpdateImpl(update);
    } catch (e, st) {
      _dmglog('DownloadManager: _onTdlibUpdate error: $e');
      debugPrint('DownloadManager: _onTdlibUpdate: $e\n$st');
    }
  }

  void _onTdlibUpdateImpl(Map<String, dynamic> update) {
    final type = update['@type'] as String?;
    if (type != 'updateFile' && type != 'update_file') return;

    final rawFile = update['file'];
    if (rawFile is! Map) return;
    final fileMap = Map<String, dynamic>.from(rawFile);

    final fileId = _parseTdlibFileId(fileMap['id']);
    if (fileId == null) return;

    final globalId = _fileIdToGlobalId[fileId];
    if (globalId == null) return;

    final rawLocal = fileMap['local'];
    if (rawLocal is! Map) return;
    final local = Map<String, dynamic>.from(rawLocal);

    final downloadedSize =
        _readInt(local, snake: 'downloaded_size', camel: 'downloadedSize') ?? 0;
    final isCompleted = _readBoolLoose(
      local,
      snake: 'is_downloading_completed',
      camel: 'isDownloadingCompleted',
    );

    final downloadedPath = _readString(local, key: 'path') ?? '';
    final row = _getRecordForGlobalId(globalId);
    final adjustedDownloaded =
        _monotonicDownloadedBytes(globalId, downloadedSize, row);
    final inferredComplete = _inferTdlibDownloadComplete(
      fileMap: fileMap,
      local: local,
      downloadedSize: adjustedDownloaded,
      path: downloadedPath,
    );

    final activeDl = _readBoolLoose(
      local,
      snake: 'is_downloading_active',
      camel: 'isDownloadingActive',
    );
    final lastLog = _lastProgressLogBytes[fileId];
    final logThis = isCompleted ||
        inferredComplete ||
        lastLog == null ||
        (adjustedDownloaded - lastLog).abs() >= 512 * 1024;
    if (logThis) {
      _lastProgressLogBytes[fileId] = adjustedDownloaded;
      _dmglog(
        'DownloadManager: updateFile fileId=$fileId globalId=$globalId '
        'rawDl=$downloadedSize uiDl=$adjustedDownloaded completed=$isCompleted '
        'inferred=$inferredComplete active=$activeDl pathLen=${downloadedPath.length}',
      );
    }

    if (isCompleted || inferredComplete) {
      _lastProgressLogBytes.remove(fileId);
      // Drop mapping immediately so a stale non-complete [updateFile] cannot
      // overwrite [DownloadCompleted] with [Downloading(0%)] (async gap before
      // [_onDownloadCompleted] ran).
      _stopCompletionPolling(fileId);
      _fileIdToGlobalId.remove(fileId);
      unawaited(_onDownloadCompleted(globalId, fileId, downloadedPath));
      return;
    } else {
      final tdExpected =
          _readInt(fileMap, snake: 'expected_size', camel: 'expectedSize');
      final persisted = row?.totalBytes;
      final totalForUi = _mergeDownloadTotals(
        tdExpected: tdExpected,
        persistedTotal: persisted,
        downloaded: adjustedDownloaded,
      );
      _setState(
        globalId,
        Downloading(
          bytesDownloaded: adjustedDownloaded,
          totalBytes: totalForUi,
        ),
      );
      _updateDbProgress(
        globalId,
        adjustedDownloaded,
        totalForUi ?? tdExpected ?? persisted,
        downloadedPath,
      );
    }
  }

  /// When TDLib omits [is_downloading_completed] but download is idle and size matches.
  ///
  /// Uses only TDLib [expected_size] (not catalog [row.totalBytes]) so a too-small
  /// persisted total cannot mark a mid-download file as finished.
  static bool _inferTdlibDownloadComplete({
    required Map<String, dynamic> fileMap,
    required Map<String, dynamic> local,
    required int downloadedSize,
    required String path,
  }) {
    if (path.trim().isEmpty) return false;
    if (_readBoolLoose(
      local,
      snake: 'is_downloading_active',
      camel: 'isDownloadingActive',
    )) {
      return false;
    }
    final tdExp =
        _readInt(fileMap, snake: 'expected_size', camel: 'expectedSize');
    if (tdExp == null || tdExp <= 0) return false;
    return downloadedSize >= tdExp;
  }

  /// TDLib sometimes omits or zeroes [expected_size] on intermediate [updateFile]
  /// payloads; using that raw value clears [Downloading.totalBytes] and the UI
  /// jumps from ~100% back to 0%. Prefer the max of TDLib, persisted catalog, and
  /// downloaded bytes until [is_downloading_completed].
  static int? _mergeDownloadTotals({
    required int? tdExpected,
    required int? persistedTotal,
    required int downloaded,
  }) {
    var best = 0;
    if (tdExpected != null && tdExpected > 0) best = tdExpected;
    if (persistedTotal != null && persistedTotal > best) best = persistedTotal;
    if (downloaded > best) best = downloaded;
    return best > 0 ? best : null;
  }

  void _beginCompletionPolling(String globalId, int fileId) {
    _stopCompletionPolling(fileId);
    _completionPollers[fileId] = Timer.periodic(_kCompletionPollInterval, (_) {
      unawaited(_pollDownloadCompletion(globalId, fileId));
    });
    _dmglog(
      'DownloadManager: completion poll started fileId=$fileId globalId=$globalId',
    );
  }

  void _stopCompletionPolling(int fileId) {
    final t = _completionPollers.remove(fileId);
    t?.cancel();
    _pollStallTrackers.remove(fileId);
  }

  int _monotonicDownloadedBytes(
    String globalId,
    int reported,
    MediaDownloadRecord? row,
  ) {
    var best = reported;
    final persisted = row?.bytesDownloaded ?? 0;
    if (persisted > best) best = persisted;
    final st = _states[globalId];
    if (st is Downloading && st.bytesDownloaded > best) {
      best = st.bytesDownloaded;
    } else if (st is DownloadPaused && st.bytesDownloaded > best) {
      best = st.bytesDownloaded;
    }
    if (best > reported) {
      _dmglog(
        'DownloadManager: monotonic clamp reported=$reported -> $best '
        'globalId=$globalId (leanback/regressive updateFile)',
      );
    }
    return best;
  }

  Future<void> _handleStalledDownload({
    required String globalId,
    required int fileId,
    required td.File file,
  }) async {
    final got = file.local.downloadedSize;
    _dmglog(
      'DownloadManager: stalled inactive+incomplete fileId=$fileId '
      'globalId=$globalId tdDownloaded=$got — pausing for resume',
    );
    _stopCompletionPolling(fileId);
    _lastProgressLogBytes.remove(fileId);
    try {
      await _tdlib.send(
        td.CancelDownloadFile(fileId: fileId, onlyIfPending: false),
      );
    } catch (e) {
      _dmglog('DownloadManager: CancelDownloadFile on stall: $e');
    }
    _fileIdToGlobalId.remove(fileId);

    final row = _getRecordForGlobalId(globalId);
    if (row == null) return;

    final d = max(row.bytesDownloaded, got);
    row.status = 'paused';
    row.bytesDownloaded = d;
    row.updatedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      await _saveRecords();
    } catch (e) {
      _dmglog('DownloadManager: _saveRecords on stall: $e');
    }

    _setState(
      globalId,
      DownloadPaused(
        bytesDownloaded: d,
        totalBytes: row.totalBytes,
      ),
    );
  }

  Future<void> _pollDownloadCompletion(String globalId, int fileId) async {
    if (_fileIdToGlobalId[fileId] != globalId) {
      _stopCompletionPolling(fileId);
      return;
    }
    if (_states[globalId] is DownloadCompleted) {
      _stopCompletionPolling(fileId);
      return;
    }
    try {
      final obj = await _tdlib.send(td.GetFile(fileId: fileId));
      if (obj is! td.File) return;

      if (obj.local.isDownloadingCompleted) {
        _stopCompletionPolling(fileId);
        if (_fileIdToGlobalId[fileId] != globalId) return;
        _fileIdToGlobalId.remove(fileId);
        _dmglog(
          'DownloadManager: completion via GetFile poll fileId=$fileId globalId=$globalId',
        );
        await _onDownloadCompleted(globalId, fileId, obj.local.path);
        return;
      }

      final active = obj.local.isDownloadingActive;
      final d = obj.local.downloadedSize;
      final tr = _pollStallTrackers.putIfAbsent(fileId, _PollStallTracker.new);

      if (active) {
        tr.stagnantPolls = 0;
        tr.lastDownloaded = d;
        return;
      }

      if (d != tr.lastDownloaded) {
        tr.stagnantPolls = 0;
        tr.lastDownloaded = d;
        return;
      }

      tr.stagnantPolls++;
      if (tr.stagnantPolls >= _kStallPollTicks) {
        await _handleStalledDownload(
          globalId: globalId,
          fileId: fileId,
          file: obj,
        );
      }
    } catch (e, st) {
      _dmglog('DownloadManager: completion poll failed fileId=$fileId: $e');
      debugPrint('DownloadManager: completion poll: $e\n$st');
    }
  }

  static int? _parseTdlibFileId(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Future<void> _onDownloadCompleted(
    String globalId,
    int fileId,
    String tdlibPath,
  ) async {
    if (_states[globalId] is DownloadCompleted) {
      _dmglog(
        'DownloadManager: _onDownloadCompleted skip (already done) globalId=$globalId',
      );
      return;
    }
    if (!_finalizingCompletion.add(globalId)) {
      _dmglog(
        'DownloadManager: _onDownloadCompleted ignored (in progress) globalId=$globalId',
      );
      return;
    }
    try {
      _dmglog(
        'DownloadManager: download completed globalId=$globalId path=$tdlibPath',
      );

      try {
        var path = tdlibPath.trim();
        if (path.isEmpty) {
          try {
            final obj = await _tdlib.send(td.GetFile(fileId: fileId));
            if (obj is td.File) {
              path = obj.local.path.trim();
            }
          } catch (e) {
            _dmglog('DownloadManager: GetFile after complete (empty path): $e');
          }
        }

        final row = _getRecordForGlobalId(globalId);
        if (row == null) {
          _dmglog(
            'DownloadManager: _onDownloadCompleted no row globalId=$globalId',
          );
          return;
        }
        if (path.isEmpty) {
          _setState(
            globalId,
            const DownloadError(
              message: 'Download finished but file path was empty.',
            ),
          );
          return;
        }

        row.status = 'completed';
        row.localFilePath = path;
        row.bytesDownloaded = row.totalBytes ?? row.bytesDownloaded;
        row.updatedAt = DateTime.now().millisecondsSinceEpoch;

        _fileIdToGlobalId.remove(fileId);
        _unavailableGlobalIds.remove(globalId);
        _setState(globalId, DownloadCompleted(localFilePath: path));

        try {
          await _saveRecords();
        } catch (e) {
          _dmglog('DownloadManager: _saveRecords after complete: $e');
        }
      } catch (e, st) {
        _dmglog('DownloadManager: _onDownloadCompleted error: $e');
        debugPrint('DownloadManager: _onDownloadCompleted: $e\n$st');
        _setState(globalId, DownloadError(message: e.toString()));
      }
    } finally {
      _finalizingCompletion.remove(globalId);
    }
  }

  Future<void> _updateDbProgress(
      String globalId, int downloaded, int? total, String? localPath) async {
    try {
      final row = _getRecordForGlobalId(globalId);
      if (row == null) return;
      
      row.bytesDownloaded = downloaded;
      if (total != null) row.totalBytes = total;
      if (localPath != null && localPath.trim().isNotEmpty) {
        row.localFilePath = localPath.trim();
      }
      row.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _saveRecords();
    } catch (_) {}
  }

  void _setState(String globalId, DownloadState state) {
    _states[globalId] = state;
    notifyListeners();
  }

  /// Human-readable filename: movie `Title (2024).mp4`, series `Title S01E02.mkv`.
  static String _buildDownloadFileName({
    required String mediaTitle,
    String releaseYear = '',
    bool isSeriesMedia = false,
    int? season,
    int? episode,
    String? quality,
    required String ext,
  }) {
    final base = _sanitizeFileNameStem(mediaTitle);
    final year = releaseYear.trim();

    String stem;
    if (isSeriesMedia) {
      final s = (season ?? 1).clamp(0, 999);
      final e = (episode != null && episode > 0) ? episode.clamp(0, 999) : 0;
      final sStr = s.toString().padLeft(2, '0');
      final eStr = e.toString().padLeft(2, '0');
      stem = '$base S${sStr}E$eStr';
    } else if (year.isNotEmpty) {
      stem = '$base ($year)';
    } else {
      stem = base;
    }

    final q = (quality ?? '').trim();
    if (q.isNotEmpty) {
      final qs = _sanitizeFileNameStem(q).replaceAll(RegExp(r'\s+'), '');
      if (qs.isNotEmpty) {
        stem = '$stem $qs';
      }
    }

    final safeExt =
        ext.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
    final extUse = safeExt.isEmpty ? 'mkv' : safeExt;
    return '$stem.$extUse';
  }

  /// Keeps Unicode letters/numbers; strips path-forbidden characters.
  static String _sanitizeFileNameStem(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return 'video';
    final buf = StringBuffer();
    for (final rune in s.runes) {
      final c = String.fromCharCode(rune);
      if (rune == 0) continue;
      if (rune < 32) continue;
      if ('<>:"/\\|?*'.contains(c)) {
        buf.write('_');
      } else {
        buf.write(c);
      }
    }
    s = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    while (s.endsWith(' ') || s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    s = s.trim();
    if (s.isEmpty) return 'video';
    if (s.length > 180) {
      s = s.substring(0, 180).trim();
    }
    return s;
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

  static int? _readInt(
    Map<String, dynamic> map, {
    required String snake,
    required String camel,
  }) {
    final value = map[snake] ?? map[camel];
    return (value as num?)?.toInt();
  }

  /// TDLib JSON occasionally uses non-bool truthy values; strict [as bool] would skip updates.
  static bool _readBoolLoose(
    Map<String, dynamic> map, {
    required String snake,
    required String camel,
  }) {
    final value = map[snake] ?? map[camel];
    if (value == null) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final s = value.toLowerCase().trim();
      return s == 'true' || s == '1';
    }
    return false;
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
    for (final t in _completionPollers.values) {
      t.cancel();
    }
    _completionPollers.clear();
    _pollStallTrackers.clear();
    _updateSub?.cancel();
    super.dispose();
  }
}

