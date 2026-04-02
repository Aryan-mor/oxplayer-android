import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;

import '../core/debug/app_debug_log.dart';
import '../telegram/media_file_locator_resolver.dart';
import '../telegram/tdlib_facade.dart';

void _dmglog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.download);

const _kDownloadPriority = 1;
const _kDownloadLimit = 0; // 0 => unlimited/chunking handled by TDLib
const _kPrefsKey = 'telecima_downloads';

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
    /// Matches captioner lines like `#tag_F_<id>` (from [AppConfig.indexTag]).
    String? indexTagForFileSearch,
    /// After provider [copyMessage], media lives in the user–bot private chat — not the index source.
    String? providerBotUsernameForDownloads,
  })  : _tdlib = tdlib,
        _recoverFromBackup = recoverFromBackup,
        _afterBackupRecoveryRefresh = afterBackupRecoveryRefresh,
        _reloadLocatorAfterRecovery = reloadLocatorAfterRecovery,
        _indexTagForFileSearch = indexTagForFileSearch,
        _providerBotUsernameForDownloads = providerBotUsernameForDownloads {
    _updateSub = tdlib.updates().listen(_onTdlibUpdate);
  }

  final TdlibFacade _tdlib;
  final Future<bool> Function(String mediaFileId)? _recoverFromBackup;
  final Future<void> Function()? _afterBackupRecoveryRefresh;
  final Future<DownloadLocatorRefresh?> Function(String globalId, String variantId)?
      _reloadLocatorAfterRecovery;
  final String? _indexTagForFileSearch;
  final String? _providerBotUsernameForDownloads;
  StreamSubscription<Map<String, dynamic>>? _updateSub;

  final Map<String, DownloadState> _states = {};
  final Map<int, String> _fileIdToGlobalId = {};
  final Set<String> _unavailableGlobalIds = {};

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
      'locatorType=$locatorType locatorChatId=$locatorChatId locatorMessageId=$locatorMessageId',
    );

    _setState(globalId, const DownloadLocating());

    try {
      bool recoveryAttempted = false;
      final mediaFileIdTrim = mediaFileId?.trim() ?? '';
      final resolvedMediaFileId =
          mediaFileIdTrim.isNotEmpty ? mediaFileIdTrim : variantId;
      final resolved = await resolveTelegramMediaFile(
        tdlib: _tdlib,
        mediaFileId: resolvedMediaFileId,
        indexTagForFileSearch: _indexTagForFileSearch ?? '',
        telegramFileId: telegramFileId,
        sourceChatId: sourceChatId,
        locatorType: locatorType,
        locatorChatId: locatorChatId,
        locatorMessageId: locatorMessageId,
        locatorBotUsername: locatorBotUsername,
        locatorRemoteFileId: locatorRemoteFileId,
        providerBotUsername: _providerBotUsernameForDownloads,
        recoverFromBackup: (allowBackupRecovery && _recoverFromBackup != null)
            ? (id) async {
                recoveryAttempted = true;
                return _recoverFromBackup(id);
              }
            : null,
      );
      td.File? tdFile = resolved?.file;
      if (tdFile == null && msgId != null && msgId > 0 && chatId != null && chatId != 0) {
        try {
          final msgObj =
              await _tdlib.send(td.GetMessage(chatId: chatId, messageId: msgId));
          if (msgObj is td.Message) {
            tdFile = _extractFileFromMessage(msgObj);

            if (tdFile == null && msgObj.replyTo is td.MessageReplyToMessage) {
              final replyToId =
                  (msgObj.replyTo as td.MessageReplyToMessage).messageId;
              try {
                final repliedObj = await _tdlib.send(
                  td.GetMessage(chatId: chatId, messageId: replyToId),
                );
                if (repliedObj is td.Message) {
                  tdFile = _extractFileFromMessage(repliedObj);
                }
              } on td.TdError catch (e) {
                _dmglog(
                  'DownloadManager: GetMessage(replyTo) failed chatId=$chatId '
                  'messageId=$replyToId code=${e.code}',
                );
              }
            }
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

      if (recoveryAttempted && _afterBackupRecoveryRefresh != null) {
        try {
          await _afterBackupRecoveryRefresh();
        } catch (e) {
          _dmglog('DownloadManager: post-recovery refresh failed: $e');
        }
      }

      _setState(
        globalId,
        Downloading(
          bytesDownloaded: tdFile.local.downloadedSize,
          totalBytes: fileSize ?? (tdFile.expectedSize > 0 ? tdFile.expectedSize : null),
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
      
      var row = _getRecordForGlobalId(globalId);
      final initialLocalPath = tdFile.local.path.trim();
      if (row != null) {
        row.status = 'downloading';
        row.bytesDownloaded = tdFile.local.downloadedSize;
        row.totalBytes = fileSize ?? (tdFile.expectedSize > 0 ? tdFile.expectedSize : null);
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
          totalBytes: fileSize ?? (tdFile.expectedSize > 0 ? tdFile.expectedSize : null),
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

      await _tdlib.send(td.DownloadFile(
        fileId: tdFile.id,
        priority: _kDownloadPriority,
        offset: 0,
        limit: _kDownloadLimit,
        synchronous: false,
      ));
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
      );
    }
  }

  static bool _isMissingTelegramFileError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('file metadata missing') ||
        s.contains('cannot identify file');
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
      _fileIdToGlobalId[row.tdlibFileId!] = globalId;
      await _tdlib.send(td.DownloadFile(
        fileId: row.tdlibFileId!,
        priority: _kDownloadPriority,
        offset: 0,
        limit: _kDownloadLimit,
        synchronous: false,
      ));

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
      unawaited(_onDownloadCompleted(globalId, fileId, downloadedPath));
    } else {
      final expectedSize =
          _readInt(fileMap, snake: 'expected_size', camel: 'expectedSize');
      _setState(
        globalId,
        Downloading(bytesDownloaded: downloadedSize, totalBytes: expectedSize),
      );
      _updateDbProgress(globalId, downloadedSize, expectedSize, downloadedPath);
    }
  }

  Future<void> _onDownloadCompleted(
    String globalId,
    int fileId,
    String tdlibPath,
  ) async {
    _dmglog(
      'DownloadManager: download completed globalId=$globalId path=$tdlibPath',
    );

    try {
      final row = _getRecordForGlobalId(globalId);
      if (row == null) return;
      if (tdlibPath.trim().isEmpty) {
        _setState(
          globalId,
          const DownloadError(message: 'Download finished but file path was empty.'),
        );
        return;
      }

      row.status = 'completed';
      row.localFilePath = tdlibPath;
      row.bytesDownloaded = row.totalBytes ?? row.bytesDownloaded;
      row.updatedAt = DateTime.now().millisecondsSinceEpoch;

      _fileIdToGlobalId.remove(fileId);
      _unavailableGlobalIds.remove(globalId);
      _setState(globalId, DownloadCompleted(localFilePath: tdlibPath));

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
