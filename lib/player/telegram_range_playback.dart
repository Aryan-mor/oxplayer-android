import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tdlib/td_api.dart' as td;

import '../core/debug/app_debug_log.dart';
import '../telegram/media_file_locator_resolver.dart';
import '../telegram/tdlib_facade.dart';

void _streamLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

const int _kServeWindowBytes = 2 * 1024 * 1024;
const int _kPrefetchBytes = 2 * 1024 * 1024;
const int _kMaxTdlibDownloadLimit = 4 * 1024 * 1024;

class TelegramRangePlayback {
  TelegramRangePlayback._();

  static final TelegramRangePlayback instance = TelegramRangePlayback._();

  HttpServer? _server;
  TdlibFacade? _tdlib;
  int? _activeFileId;
  String? _activeLocalPath;
  int _activeTotalBytes = 0;
  int _downloadOffset = 0;
  int _downloadPrefixSize = 0;
  int _downloadedSize = 0;
  String _activeMime = 'video/*';

  Future<Uri?> open({
    required TdlibFacade tdlib,
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
    required String mediaTitle,
    required String displayTitle,
    String releaseYear = '',
    bool isSeriesMedia = false,
    int? season,
    int? episode,
    String? quality,
    String? mimeType,
    int? fileSize,
    String? indexTagForFileSearch,
    String? providerBotUsername,
    Future<bool> Function(String mediaFileId)? recoverFromBackup,
  }) async {
    _tdlib = tdlib;
    _activeFileId = null;
    _activeLocalPath = null;
    _activeTotalBytes = 0;
    _downloadOffset = 0;
    _downloadPrefixSize = 0;
    _downloadedSize = 0;
    _activeMime = (mimeType ?? '').trim().isEmpty ? 'video/*' : mimeType!.trim();

    final resolved = await resolveTelegramMediaFile(
      tdlib: tdlib,
      mediaFileId: (mediaFileId ?? '').trim().isNotEmpty ? mediaFileId!.trim() : variantId,
      indexTagForFileSearch: indexTagForFileSearch ?? '',
      telegramFileId: telegramFileId,
      sourceChatId: sourceChatId,
      locatorType: locatorType,
      locatorChatId: locatorChatId,
      locatorMessageId: locatorMessageId,
      locatorBotUsername: locatorBotUsername,
      locatorRemoteFileId: locatorRemoteFileId,
      providerBotUsername: providerBotUsername,
      recoverFromBackup: recoverFromBackup,
    );
    if (resolved == null) return null;
    final tdFile = resolved.file;

    _activeFileId = tdFile.id;
    _activeLocalPath = tdFile.local.path.trim().isEmpty ? null : tdFile.local.path.trim();
    _activeTotalBytes =
        (fileSize != null && fileSize > 0) ? fileSize : (tdFile.expectedSize > 0 ? tdFile.expectedSize : tdFile.size);
    if (_activeTotalBytes <= 0) _activeTotalBytes = fileSize ?? 0;

    await _requestRangeDownload(
      offset: 0,
      bytesToFetch: 2 * 1024 * 1024,
      synchronous: true,
    );
    final runtimeReady = await _waitForRuntimeReady(timeout: const Duration(seconds: 20));
    if (!runtimeReady) return null;

    await _ensureServer();
    final port = _server?.port;
    if (port == null) return null;
    return Uri.parse('http://127.0.0.1:$port/stream');
  }

  Future<void> _ensureServer() async {
    if (_server != null) return;
    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_handleRequest);
    _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    _streamLog('RangePlayback: started on ${_server!.address.host}:${_server!.port}');
  }

  Future<Response> _handleRequest(Request request) async {
    _streamLog(
      'RangePlayback: request method=${request.method} '
      'range="${request.headers[HttpHeaders.rangeHeader] ?? ''}"',
    );
    if (request.url.path != 'stream') {
      return Response.notFound('not found');
    }
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) {
      return Response.internalServerError(body: 'stream not initialized');
    }
    final filePath = _activeLocalPath;
    if (filePath == null || filePath.trim().isEmpty) return Response.notFound('file not ready');
    final file = File(filePath);
    if (!await file.exists()) {
      return Response.notFound('file missing');
    }
    final totalBytes = _activeTotalBytes > 0 ? _activeTotalBytes : await file.length();
    if (totalBytes <= 0) {
      return Response.internalServerError(body: 'unknown file size');
    }

    if (request.method == 'HEAD') {
      return Response.ok(
        '',
        headers: {
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.contentTypeHeader: _activeMime,
          HttpHeaders.contentLengthHeader: '$totalBytes',
        },
      );
    }

    final hdr = request.headers[HttpHeaders.rangeHeader];
    final parsed = _parseRange(hdr, totalBytes);
    if (parsed == null) {
      _streamLog('RangePlayback: invalid range header="$hdr" total=$totalBytes');
      return Response(
        HttpStatus.requestedRangeNotSatisfiable,
        headers: {'Content-Range': 'bytes */$totalBytes'},
      );
    }
    var start = parsed.$1;
    var end = parsed.$2;
    final requestedOpenEnded = hdr != null && RegExp(r'^bytes=\d+-$').hasMatch(hdr.trim());
    if (requestedOpenEnded || (end - start + 1) > _kServeWindowBytes) {
      final chunkEnd = start + _kServeWindowBytes - 1;
      if (chunkEnd < end) {
        end = chunkEnd;
      }
    }
    final wantLength = end - start + 1;
    _streamLog('RangePlayback: parsed range start=$start end=$end want=$wantLength total=$totalBytes');

    final ok = await _waitUntilAvailable(
      requiredStart: start,
      requiredEnd: end,
      timeout: const Duration(seconds: 25),
    );
    if (!ok) {
      final available = await _currentAvailability();
      final availableEnd = available.$2;
      if (availableEnd < start) {
        _streamLog(
          'RangePlayback: range not ready start=$start avail=${available.$1}-$availableEnd',
        );
        return Response(
          HttpStatus.requestedRangeNotSatisfiable,
          headers: {'Content-Range': 'bytes */$totalBytes'},
        );
      }
      end = availableEnd;
      _streamLog('RangePlayback: partial fallback end=$end');
    }

    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(end - start + 1);
      final status = HttpStatus.partialContent;
      _streamLog(
        'RangePlayback: served status=$status bytes=${bytes.length} '
        'contentRange=$start-${start + bytes.length - 1}/$totalBytes',
      );
      return Response(
        status,
        body: bytes,
        headers: {
          HttpHeaders.acceptRangesHeader: 'bytes',
          HttpHeaders.contentTypeHeader: _activeMime,
          HttpHeaders.contentLengthHeader: '${bytes.length}',
          HttpHeaders.contentRangeHeader: 'bytes $start-${start + bytes.length - 1}/$totalBytes',
          'X-Telecima-Requested-Length': '$wantLength',
        },
      );
    } finally {
      await raf.close();
    }
  }

  Future<bool> _waitForRuntimeReady({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final hasPath = (_activeLocalPath ?? '').trim().isNotEmpty;
      final downloaded = await _currentDownloadedSize();
      if (hasPath && downloaded > 0) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<bool> _waitUntilAvailable({
    required int requiredStart,
    required int requiredEnd,
    required Duration timeout,
  }) async {
    await _requestRangeDownload(
      offset: requiredStart,
      bytesToFetch: (requiredEnd - requiredStart + 1) + _kPrefetchBytes,
      synchronous: true,
    );
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final avail = await _currentAvailability();
      if (requiredStart >= avail.$1 && requiredEnd <= avail.$2) return true;
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    return false;
  }

  Future<void> _requestRangeDownload({
    required int offset,
    required int bytesToFetch,
    bool synchronous = false,
  }) async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return;
    final requestedLimit = bytesToFetch <= 0 ? 256 * 1024 : bytesToFetch;
    final limit = requestedLimit > _kMaxTdlibDownloadLimit
        ? _kMaxTdlibDownloadLimit
        : requestedLimit;
    final safeOffset = offset < 0 ? 0 : offset;
    try {
      await tdlib.send(
        td.DownloadFile(
          fileId: fileId,
          priority: 32,
          offset: safeOffset,
          limit: limit,
          synchronous: synchronous,
        ),
      );
      _streamLog(
        'RangePlayback: request download offset=$safeOffset limit=$limit sync=$synchronous',
      );
    } catch (_) {}
  }

  Future<int> _currentDownloadedSize() async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return 0;
    try {
      final obj = await tdlib.send(td.GetFile(fileId: fileId));
      if (obj is! td.File) return 0;
      final p = obj.local.path.trim();
      if (p.isNotEmpty) _activeLocalPath = p;
      final s = obj.local.downloadedSize;
      _downloadedSize = s;
      _downloadOffset = obj.local.downloadOffset;
      _downloadPrefixSize = obj.local.downloadedPrefixSize;
      if (_activeTotalBytes <= 0) {
        _activeTotalBytes = obj.expectedSize > 0 ? obj.expectedSize : obj.size;
      }
      _streamLog(
        'RangePlayback: file local offset=$_downloadOffset '
        'prefix=$_downloadPrefixSize downloaded=$_downloadedSize total=$_activeTotalBytes '
        'pathSet=${_activeLocalPath != null}',
      );
      return s > 0 ? s : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<(int, int)> _currentAvailability() async {
    await _currentDownloadedSize();
    if (_downloadedSize <= 0) return (0, -1);
    if (_downloadPrefixSize > 0) {
      return (_downloadOffset, _downloadOffset + _downloadPrefixSize - 1);
    }
    // Fallback for TDLib builds that may not expose prefix fields.
    return (0, _downloadedSize - 1);
  }

  (int, int)? _parseRange(String? header, int totalBytes) {
    if (totalBytes <= 0) return null;
    final maxEnd = totalBytes - 1;
    if (header == null || header.isEmpty) {
      final end = maxEnd > 1024 * 1024 ? 1024 * 1024 : maxEnd;
      return (0, end);
    }
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (m == null) return null;
    final a = m.group(1) ?? '';
    final b = m.group(2) ?? '';
    int start;
    int end;
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) {
      final suffix = int.tryParse(b);
      if (suffix == null || suffix <= 0) return null;
      if (suffix >= totalBytes) return (0, maxEnd);
      return (totalBytes - suffix, maxEnd);
    }
    start = int.tryParse(a) ?? -1;
    if (start < 0 || start >= totalBytes) return null;
    if (b.isEmpty) {
      end = maxEnd;
    } else {
      end = int.tryParse(b) ?? -1;
      if (end < start) return null;
      if (end > maxEnd) end = maxEnd;
    }
    return (start, end);
  }
}
