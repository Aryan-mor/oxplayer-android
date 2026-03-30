import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;

import '../core/debug/app_debug_log.dart';
import '../telegram/tdlib_facade.dart';

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

  factory MediaDownloadRecord.fromJson(Map<String, dynamic> json) {
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
  }) : _tdlib = tdlib {
    _updateSub = tdlib.updates().listen(_onTdlibUpdate);
  }

  final TdlibFacade _tdlib;
  StreamSubscription<Map<String, dynamic>>? _updateSub;

  final Map<String, DownloadState> _states = {};
  final Map<int, String> _fileIdToGlobalId = {};

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
    int? msgId,
    int? chatId,
    required String title,
    required String year,
    String? mimeType,
    int? fileSize,
  }) async {
    if (_states[globalId] is Downloading) return;

    AppDebugLog.instance.log(
      'DownloadManager: startDownload globalId=$globalId variantId=$variantId',
    );

    _setState(globalId, const Downloading(bytesDownloaded: 0, totalBytes: null));

    try {
      td.File? tdFile;

      if (telegramFileId != null && telegramFileId.isNotEmpty) {
        final remoteFile = await _tdlib.send(td.GetRemoteFile(remoteFileId: telegramFileId, fileType: null));
        if (remoteFile is td.File) {
          tdFile = remoteFile;
        } else {
          throw Exception('Could not resolve remote file ID: $telegramFileId');
        }
      } else if (msgId != null && msgId > 0 && chatId != null && chatId != 0) {
        final msgObj =
            await _tdlib.send(td.GetMessage(chatId: chatId, messageId: msgId));
        if (msgObj is! td.Message) {
          throw Exception('Could not retrieve message $msgId from chat $chatId');
        }

        if (msgObj.content is td.MessageVideo) {
          tdFile = (msgObj.content as td.MessageVideo).video.video;
        } else if (msgObj.content is td.MessageDocument) {
          tdFile = (msgObj.content as td.MessageDocument).document.document;
        }

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
      }

      if (tdFile == null) {
        throw Exception('File metadata missing; cannot identify file to download.');
      }

      final ext = _extensionFromMime(mimeType) ??
          _extensionFromFileName(tdFile.local.path) ??
          'mkv';
      final standardizedName = _buildStandardizedName(title, year, ext);

      final downloadId = '$globalId:$variantId';
      final now = DateTime.now().millisecondsSinceEpoch;
      
      var row = _getRecordForGlobalId(globalId);
      if (row != null) {
        row.status = 'downloading';
        row.bytesDownloaded = tdFile.local.downloadedSize;
        row.totalBytes = fileSize ?? (tdFile.expectedSize > 0 ? tdFile.expectedSize : null);
        row.updatedAt = now;
        row.tdlibFileId = tdFile.id;
        row.standardizedName = standardizedName;
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
      AppDebugLog.instance.log('DownloadManager: startDownload error: $e');
      debugPrint('DownloadManager: startDownload: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
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
      AppDebugLog.instance.log('DownloadManager: pauseDownload error: $e');
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
      AppDebugLog.instance.log('DownloadManager: resumeDownload error: $e');
      debugPrint('DownloadManager: resumeDownload: $e\n$st');
      _setState(globalId, DownloadError(message: e.toString()));
    }
  }

  Future<void> deleteDownload(String globalId) async {
    AppDebugLog.instance.log('DownloadManager: deleteDownload $globalId');
    
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
      final row = _getRecordForGlobalId(globalId);
      if (row == null) return;

      final standardizedName = row.standardizedName ?? row.fileName;
      final destDir = await _resolveDownloadDirectory();
      final destPath = '${destDir.path}/$standardizedName';

      String finalPath;
      try {
        await File(tdlibPath).rename(destPath);
        finalPath = destPath;
      } catch (_) {
        await File(tdlibPath).copy(destPath);
        await File(tdlibPath).delete();
        finalPath = destPath;
      }

      AppDebugLog.instance.log(
        'DownloadManager: renamed to $finalPath',
      );

      row.status = 'completed';
      row.localFilePath = finalPath;
      row.bytesDownloaded = row.totalBytes ?? row.bytesDownloaded;
      row.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _saveRecords();

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
      final row = _getRecordForGlobalId(globalId);
      if (row == null) return;
      
      row.bytesDownloaded = downloaded;
      if (total != null) row.totalBytes = total;
      row.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await _saveRecords();
    } catch (_) {}
  }

  void _setState(String globalId, DownloadState state) {
    _states[globalId] = state;
    notifyListeners();
  }

  static String _buildStandardizedName(
      String title, String year, String ext) {
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
