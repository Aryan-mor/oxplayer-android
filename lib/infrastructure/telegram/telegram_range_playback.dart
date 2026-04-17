import 'dart:async';
import 'dart:io';

import 'package:tdlib/td_api.dart' as td;

import 'tdlib_facade.dart';

const int _kChunkBytes = 2 * 1024 * 1024;
const int _kPrefetchBytes = 2 * 1024 * 1024;
const int _kMaxTdlibLimit = 4 * 1024 * 1024;
const int _kSeekThresholdBytes = 8 * 1024 * 1024;
const int _kSeekAlignBytes = 512 * 1024;
const int _kFarSeekSyncMinOffsetBytes = 32 * 1024 * 1024;
const int _kFarSeekSyncBootstrapBytes = 768 * 1024;
const int _kMinPrefixBytesForSyncFirst = 768 * 1024;
const Duration _kWaitTimeout = Duration(seconds: 120);
const Duration _kRepoke = Duration(seconds: 2);
const Duration _kRepokeStarved = Duration(milliseconds: 500);
const Duration _kPollInterval = Duration(milliseconds: 100);
const Duration _kSeekEarlyPartialAfter = Duration(milliseconds: 1200);
const int _kSeekEarlyPartialMinBytes = 512 * 1024;
const Duration _kSyncTdlibDownloadTimeout = Duration(seconds: 25);
const Duration _kSeekStallRecoverAfter = Duration(seconds: 45);

class TelegramRangePlayback {
  TelegramRangePlayback._();

  static final TelegramRangePlayback instance = TelegramRangePlayback._();

  HttpServer? _server;
  TdlibFacade? _tdlib;
  int _playbackEpoch = 0;
  int? _activeFileId;
  String? _activeLocalPath;
  int _activeTotalBytes = 0;
  int _downloadOffset = 0;
  int _downloadPrefixSize = 0;
  String _activeMime = 'video/*';
  String? _lastOpenFailureReason;
  int _lastPokeOffset = -1;
  DateTime _lastPokeAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastServedEnd = -1;

  String? get lastOpenFailureReason => _lastOpenFailureReason;

  Future<Uri?> openResolvedFile({
    required TdlibFacade tdlib,
    required td.File file,
    String? mimeType,
    void Function(String message)? onDiagnostic,
  }) async {
    _lastOpenFailureReason = null;
    _playbackEpoch++;
    await _stopLoopbackServerIfAny();

    final previousTdlib = _tdlib;
    final previousFileId = _activeFileId;
    if (previousTdlib != null && previousFileId != null) {
      await _cancelAndDelete(tdlib: previousTdlib, fileId: previousFileId);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));

    _tdlib = tdlib;
    _activeFileId = file.id;
    _activeLocalPath = file.local.path.trim().isEmpty ? null : file.local.path.trim();
    _activeTotalBytes = _bestFileSize(file);
    _downloadOffset = 0;
    _downloadPrefixSize = 0;
    _lastPokeOffset = -1;
    _lastPokeAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastServedEnd = -1;
    _activeMime = (mimeType ?? '').trim().isEmpty ? 'video/*' : mimeType!.trim();

    onDiagnostic?.call(
      'Opening Telegram range playback for fileId=${file.id} totalBytes=$_activeTotalBytes',
    );

    try {
      await _download(offset: 0, bytes: _kChunkBytes, synchronous: true)
          .timeout(_kSyncTdlibDownloadTimeout);
    } on TimeoutException {
      onDiagnostic?.call(
        'Initial synchronous download timed out for fileId=${file.id}. Falling back to async bootstrap.',
      );
      await _download(offset: 0, bytes: _kChunkBytes, synchronous: false);
    }

    final ready = await _waitForPath(const Duration(seconds: 20));
    if (!ready) {
      _lastOpenFailureReason = 'tdlib_path_timeout';
      onDiagnostic?.call('Telegram range playback failed: path not ready for fileId=${file.id}');
      return null;
    }

    await _ensureServer(onDiagnostic: onDiagnostic);
    final port = _server?.port;
    if (port == null) {
      _lastOpenFailureReason = 'loopback_server_failed';
      onDiagnostic?.call('Telegram range playback failed: loopback server did not start for fileId=${file.id}');
      return null;
    }

    final url = Uri.parse('http://127.0.0.1:$port/stream');
    onDiagnostic?.call('Telegram range playback ready at $url for fileId=${file.id}');
    return url;
  }

  Future<int> releaseActiveCacheIfAny({String? reason}) async {
    _playbackEpoch++;
    await _stopLoopbackServerIfAny();

    final previousTdlib = _tdlib;
    final previousFileId = _activeFileId;
    _tdlib = null;
    _activeFileId = null;
    _activeLocalPath = null;
    _activeTotalBytes = 0;
    _downloadOffset = 0;
    _downloadPrefixSize = 0;
    _lastPokeOffset = -1;
    _lastServedEnd = -1;

    if (previousTdlib != null && previousFileId != null) {
      await _cancelAndDelete(tdlib: previousTdlib, fileId: previousFileId);
      return 1;
    }
    return 0;
  }

  Future<void> _stopLoopbackServerIfAny() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    try {
      await server.close(force: true);
    } catch (_) {}
  }

  Future<void> _ensureServer({void Function(String message)? onDiagnostic}) async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (request) => unawaited(_handleRequest(request)),
      onError: (_) {},
      cancelOnError: false,
    );
    _server = server;
    onDiagnostic?.call('Started Telegram range loopback server on ${server.address.host}:${server.port}');
    // Let the isolate process the listening socket before clients connect (avoids rare connection refused).
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path != '/stream') {
        await _writeResponse(request.response, HttpStatus.notFound, body: 'not found');
        return;
      }

      final playbackEpoch = _playbackEpoch;
      final tdlib = _tdlib;
      final fileId = _activeFileId;
      final filePath = _activeLocalPath;
      if (tdlib == null || fileId == null || filePath == null || filePath.isEmpty) {
        await _writeResponse(request.response, HttpStatus.internalServerError, body: 'not initialized');
        return;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        await _writeResponse(request.response, HttpStatus.notFound, body: 'file missing');
        return;
      }

      final totalBytes = _activeTotalBytes > 0 ? _activeTotalBytes : await file.length();
      if (totalBytes <= 0) {
        await _writeResponse(request.response, HttpStatus.internalServerError, body: 'unknown size');
        return;
      }

      if (request.method == 'HEAD') {
        if (_stalePlaybackEpoch(playbackEpoch)) {
          await _writeResponse(request.response, HttpStatus.serviceUnavailable, body: 'playback ended');
          return;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentTypeHeader, _activeMime)
          ..set(HttpHeaders.contentLengthHeader, '$totalBytes');
        await request.response.close();
        return;
      }

      final parsed = _parseRange(request.headers.value(HttpHeaders.rangeHeader), totalBytes);
      if (parsed == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalBytes');
        await request.response.close();
        return;
      }

      var start = parsed.$1;
      var end = parsed.$2;
      final header = request.headers.value(HttpHeaders.rangeHeader);
      if ((header != null && RegExp(r'^bytes=\d+-$').hasMatch(header.trim())) ||
          (end - start + 1) > _kChunkBytes) {
        final cappedEnd = start + _kChunkBytes - 1;
        if (cappedEnd < end) end = cappedEnd;
      }

      if (_stalePlaybackEpoch(playbackEpoch)) {
        await _writeResponse(request.response, HttpStatus.serviceUnavailable, body: 'playback ended');
        return;
      }

      final isSeek = _isSeek(start);
      if (isSeek) {
        await _handleSeek(start);
      }

      if (_stalePlaybackEpoch(playbackEpoch)) {
        await _writeResponse(request.response, HttpStatus.serviceUnavailable, body: 'playback ended');
        return;
      }

      final waitResult = await _waitForRange(
        start,
        end,
        playbackEpoch: playbackEpoch,
        syncFirstPoke: !isSeek,
        isSeek: isSeek,
      );
      if (waitResult.abortedStale) {
        await _writeResponse(request.response, HttpStatus.serviceUnavailable, body: 'playback ended');
        return;
      }

      if (!waitResult.ok) {
        final available = waitResult.lastAvail;
        if (available <= 0) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalBytes');
          await request.response.close();
          return;
        }
        final partialEnd = start + available - 1;
        if (partialEnd < end) end = partialEnd;
      }

      if (_stalePlaybackEpoch(playbackEpoch)) {
        await _writeResponse(request.response, HttpStatus.serviceUnavailable, body: 'playback ended');
        return;
      }

      // Hard cap per response: never read more than [_kChunkBytes] into memory. A regression
      // or unusual Range header could otherwise request ~1GB+ and OOM-kill the Dart isolate
      // (seen as a silent crash during MPV/ffmpeg probe of large Telegram files).
      {
        final span = end - start + 1;
        if (span > _kChunkBytes) {
          end = start + _kChunkBytes - 1;
          if (end >= totalBytes) end = totalBytes - 1;
        }
        if (end < start) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalBytes');
          await request.response.close();
          return;
        }
      }

      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(end - start + 1);
        _lastServedEnd = start + bytes.length - 1;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentTypeHeader, _activeMime)
          ..set(HttpHeaders.contentLengthHeader, '${bytes.length}')
          ..set(HttpHeaders.contentRangeHeader, 'bytes $start-${start + bytes.length - 1}/$totalBytes');
        request.response.add(bytes);
        await request.response.close();
      } finally {
        await raf.close();
      }
    } catch (_) {
      try {
        await _writeResponse(request.response, HttpStatus.internalServerError, body: 'stream error');
      } catch (_) {}
    }
  }

  Future<void> _writeResponse(HttpResponse response, int statusCode, {String? body}) async {
    response.statusCode = statusCode;
    if (body != null) {
      response.write(body);
    }
    await response.close();
  }

  bool _stalePlaybackEpoch(int epoch) => epoch != _playbackEpoch;

  bool _isSeek(int requestStart) {
    if (_lastServedEnd < 0) return false;
    final gap = (requestStart - (_lastServedEnd + 1)).abs();
    return gap > _kSeekThresholdBytes;
  }

  Future<void> _handleSeek(int newOffset) async {
    final aligned = (newOffset ~/ _kSeekAlignBytes) * _kSeekAlignBytes;
    final nearEnd = _activeTotalBytes > 0 && aligned + _kChunkBytes >= _activeTotalBytes - (512 * 1024);
    final farBody = aligned >= _kFarSeekSyncMinOffsetBytes;
    final useSyncBootstrap = farBody && !nearEnd;

    if (useSyncBootstrap) {
      try {
        await _download(
          offset: aligned,
          bytes: _kFarSeekSyncBootstrapBytes,
          synchronous: true,
        ).timeout(_kSyncTdlibDownloadTimeout);
      } on TimeoutException {
        // Fall back to async repoke below.
      }
    }

    await _download(
      offset: aligned,
      bytes: _kChunkBytes + _kPrefetchBytes,
      synchronous: false,
    );
  }

  Future<({bool ok, bool abortedStale, int elapsedMs, int repokes, int lastAvail, int need})> _waitForRange(
    int start,
    int end, {
    required int playbackEpoch,
    required bool syncFirstPoke,
    required bool isSeek,
  }) async {
    final t0 = DateTime.now();
    final need = end - start + 1;
    final pokeOffset = isSeek ? (start ~/ _kSeekAlignBytes) * _kSeekAlignBytes : start;
    await _refreshLocal();
    var lastAvail = await _availAtRangeStart(start, isSeek: isSeek);

    if (_stalePlaybackEpoch(playbackEpoch)) {
      return (
        ok: false,
        abortedStale: true,
        elapsedMs: DateTime.now().difference(t0).inMilliseconds,
        repokes: 0,
        lastAvail: lastAvail,
        need: need,
      );
    }

    if (lastAvail >= need) {
      return (
        ok: true,
        abortedStale: false,
        elapsedMs: DateTime.now().difference(t0).inMilliseconds,
        repokes: 0,
        lastAvail: lastAvail,
        need: need,
      );
    }

    final syncEffective = syncFirstPoke &&
        (lastAvail >= _kMinPrefixBytesForSyncFirst || lastAvail >= need ~/ 2);
    if (syncEffective) {
      try {
        await _download(
          offset: pokeOffset,
          bytes: _kChunkBytes + _kPrefetchBytes,
          synchronous: true,
        ).timeout(_kSyncTdlibDownloadTimeout);
      } on TimeoutException {
        await _download(
          offset: pokeOffset,
          bytes: _kChunkBytes + _kPrefetchBytes,
          synchronous: false,
        );
      }
    } else {
      await _download(
        offset: pokeOffset,
        bytes: _kChunkBytes + _kPrefetchBytes,
        synchronous: false,
      );
    }

    if (_stalePlaybackEpoch(playbackEpoch)) {
      return (
        ok: false,
        abortedStale: true,
        elapsedMs: DateTime.now().difference(t0).inMilliseconds,
        repokes: 0,
        lastAvail: lastAvail,
        need: need,
      );
    }

    var repokes = 0;
    var stallRecoverDone = false;
    final deadline = DateTime.now().add(_kWaitTimeout);
    var nextRepoke = DateTime.now().add(lastAvail < need ~/ 4 ? _kRepokeStarved : _kRepoke);

    while (DateTime.now().isBefore(deadline)) {
      if (_stalePlaybackEpoch(playbackEpoch)) {
        return (
          ok: false,
          abortedStale: true,
          elapsedMs: DateTime.now().difference(t0).inMilliseconds,
          repokes: repokes,
          lastAvail: lastAvail,
          need: need,
        );
      }

      await _refreshLocal();
      lastAvail = await _availAtRangeStart(start, isSeek: isSeek);

      if (isSeek &&
          lastAvail == 0 &&
          !stallRecoverDone &&
          DateTime.now().difference(t0) >= _kSeekStallRecoverAfter) {
        stallRecoverDone = true;
        final tdlib = _tdlib;
        final fileId = _activeFileId;
        if (tdlib != null && fileId != null) {
          try {
            await tdlib.send(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false));
          } catch (_) {}
          await _download(
            offset: pokeOffset,
            bytes: _kChunkBytes + _kPrefetchBytes,
            synchronous: false,
          );
        }
      }

      if (lastAvail >= need) {
        return (
          ok: true,
          abortedStale: false,
          elapsedMs: DateTime.now().difference(t0).inMilliseconds,
          repokes: repokes,
          lastAvail: lastAvail,
          need: need,
        );
      }

      if (isSeek && lastAvail >= _kSeekEarlyPartialMinBytes) {
        final elapsed = DateTime.now().difference(t0);
        if (elapsed >= _kSeekEarlyPartialAfter) {
          return (
            ok: false,
            abortedStale: false,
            elapsedMs: elapsed.inMilliseconds,
            repokes: repokes,
            lastAvail: lastAvail,
            need: need,
          );
        }
      }

      final now = DateTime.now();
      if (now.isAfter(nextRepoke)) {
        nextRepoke = now.add(lastAvail < need ~/ 4 ? _kRepokeStarved : _kRepoke);
        repokes++;
        await _download(
          offset: pokeOffset,
          bytes: _kChunkBytes + _kPrefetchBytes,
          synchronous: false,
        );
      }

      await Future<void>.delayed(_kPollInterval);
    }

    return (
      ok: false,
      abortedStale: false,
      elapsedMs: DateTime.now().difference(t0).inMilliseconds,
      repokes: repokes,
      lastAvail: lastAvail,
      need: need,
    );
  }

  Future<int> _availAtRangeStart(int start, {required bool isSeek}) async {
    if (!isSeek) return _prefixFrom(start);
    final direct = await _prefixFrom(start);
    final aligned = (start ~/ _kSeekAlignBytes) * _kSeekAlignBytes;
    final prefixAtAligned = await _prefixFrom(aligned);
    final gap = start - aligned;
    final fromAligned = prefixAtAligned > gap ? prefixAtAligned - gap : 0;
    return direct > fromAligned ? direct : fromAligned;
  }

  Future<void> _download({
    required int offset,
    required int bytes,
    bool synchronous = false,
  }) async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return;
    final limit = bytes > _kMaxTdlibLimit ? _kMaxTdlibLimit : bytes;
    final safeOffset = offset < 0 ? 0 : offset;
    final now = DateTime.now();
    if (!synchronous &&
        safeOffset == _lastPokeOffset &&
        now.difference(_lastPokeAt) < const Duration(milliseconds: 120)) {
      return;
    }

    _lastPokeOffset = safeOffset;
    _lastPokeAt = now;
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
    } catch (_) {}
  }

  Future<void> _refreshLocal() async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return;
    try {
      final obj = await tdlib.send(td.GetFile(fileId: fileId));
      if (obj is! td.File) return;
      _activeLocalPath = obj.local.path.trim().isEmpty ? _activeLocalPath : obj.local.path.trim();
      _downloadOffset = obj.local.downloadOffset;
      _downloadPrefixSize = obj.local.downloadedPrefixSize;
      final bestSize = _bestFileSize(obj);
      if (bestSize > _activeTotalBytes) {
        _activeTotalBytes = bestSize;
      }
    } catch (_) {}
  }

  Future<int> _prefixFrom(int offset) async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null || offset < 0) return 0;
    try {
      final obj = await tdlib.send(td.GetFileDownloadedPrefixSize(fileId: fileId, offset: offset));
      if (obj is td.FileDownloadedPrefixSize) return obj.size;
    } catch (_) {}

    if (_downloadPrefixSize > 0) {
      final rangeStart = _downloadOffset;
      final rangeEnd = rangeStart + _downloadPrefixSize - 1;
      if (offset >= rangeStart && offset <= rangeEnd) {
        return rangeEnd - offset + 1;
      }
    }
    return 0;
  }

  Future<bool> _waitForPath(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await _refreshLocal();
      final path = _activeLocalPath;
      if (path != null && path.isNotEmpty) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<void> _cancelAndDelete({required TdlibFacade tdlib, required int fileId}) async {
    try {
      await tdlib.send(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false));
    } catch (_) {}
    try {
      await tdlib.send(td.DeleteFile(fileId: fileId));
    } catch (_) {}
  }

  int _bestFileSize(td.File file) {
    var best = 0;
    if (file.expectedSize > best) best = file.expectedSize;
    if (file.size > best) best = file.size;
    return best;
  }

  (int, int)? _parseRange(String? header, int totalBytes) {
    if (totalBytes <= 0) return null;
    if (header == null || header.trim().isEmpty) {
      return (0, totalBytes - 1);
    }

    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;

    final startRaw = match.group(1) ?? '';
    final endRaw = match.group(2) ?? '';
    if (startRaw.isEmpty && endRaw.isEmpty) return null;

    int start;
    int end;
    if (startRaw.isEmpty) {
      final suffixLength = int.tryParse(endRaw);
      if (suffixLength == null || suffixLength <= 0) return null;
      if (suffixLength >= totalBytes) {
        start = 0;
      } else {
        start = totalBytes - suffixLength;
      }
      end = totalBytes - 1;
    } else {
      start = int.tryParse(startRaw) ?? -1;
      if (start < 0 || start >= totalBytes) return null;
      if (endRaw.isEmpty) {
        end = totalBytes - 1;
      } else {
        end = int.tryParse(endRaw) ?? -1;
        if (end < start) return null;
        if (end >= totalBytes) end = totalBytes - 1;
      }
    }

    return (start, end);
  }
}