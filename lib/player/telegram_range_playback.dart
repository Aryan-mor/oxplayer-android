import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:tdlib/td_api.dart' as td;

import '../core/debug/app_debug_log.dart';
import '../core/storage/storage_headroom.dart';
import '../telegram/media_file_locator_resolver.dart';
import '../telegram/tdlib_facade.dart';

void _streamLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

void _keyLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.stream);

void _locatorLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.locator);

// ── Tuning constants ─────────────────────────────────────────────────────────

const int _kChunkBytes = 2 * 1024 * 1024;
const int _kPrefetchBytes = 2 * 1024 * 1024;
const int _kMaxTdlibLimit = 4 * 1024 * 1024;

/// A range request whose start is more than this away from the tail of the
/// current download window is treated as a seek.
const int _kSeekThresholdBytes = 8 * 1024 * 1024;

/// After a seek is detected, wait this long before committing a cache wipe.
/// If another seek arrives during the window the timer resets.
const int _kSeekDebounceMs = 1500;

/// How long we poll for a range before giving up / falling back to partial.
const Duration _kWaitTimeout = Duration(seconds: 120);
const Duration _kRepoke = Duration(seconds: 2);
const Duration _kRepokeStarved = Duration(milliseconds: 500);
const Duration _kPollInterval = Duration(milliseconds: 100);
const Duration _kSeekEarlyPartialAfter = Duration(milliseconds: 1200);
const int _kSeekEarlyPartialMinBytes = 512 * 1024;
const int _kSeekAlignBytes = 512 * 1024;

/// Body seeks at or beyond this offset await a small synchronous [downloadFile]
/// first — async-only often leaves prefix at 0 for tens of seconds on large files.
const int _kFarSeekSyncMinOffsetBytes = 32 * 1024 * 1024;

/// Small sync chunk at far seek — enough to prime TDLib without a multi‑second
/// 4 MiB block like the full window.
const int _kFarSeekSyncBootstrapBytes = 768 * 1024;

/// [DownloadFile(synchronous: true)] can block the HTTP isolate without bound if
/// TDLib/native stalls — never await it longer than this (then fall back async).
const Duration _kSyncTdlibDownloadTimeout = Duration(seconds: 25);

/// If a far seek still shows no bytes after this, cancel+repoke once to unstick.
const Duration _kSeekStallRecoverAfter = Duration(seconds: 45);

/// Never use synchronous [downloadFile] when the prefix at [start] is below this.
/// A cold sync can block the HTTP handler for 30s+ while TDLib fills ~4 MiB.
const int _kMinPrefixBytesForSyncFirst = 768 * 1024;

/// Wipe the TDLib file cache when total downloaded bytes exceed this.
const int _kMaxCacheBeforeTrimBytes = 150 * 1024 * 1024;

// ── Class ────────────────────────────────────────────────────────────────────

class TelegramRangePlayback {
  TelegramRangePlayback._();

  static final TelegramRangePlayback instance = TelegramRangePlayback._();

  /// Approximate bytes TDLib holds for the active range stream (0 if idle).
  int get activeStreamCacheBytes => _downloadedSize;
  String? get lastOpenFailureReason => _lastOpenFailureReason;

  HttpServer? _server;
  TdlibFacade? _tdlib;

  /// Bumped on each [open] / [releaseActiveCacheIfAny] so stale loopback
  /// handlers exit and stop calling TDLib (fixes second stream hanging after Back).
  int _playbackEpoch = 0;
  int? _activeFileId;
  String? _activeLocalPath;
  int _activeTotalBytes = 0;
  int _downloadOffset = 0;
  int _downloadPrefixSize = 0;
  int _downloadedSize = 0;
  String _activeMime = 'video/*';
  String? _lastOpenFailureReason;
  int _lastPokeOffset = -1;
  DateTime _lastPokeAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// End (inclusive) of the last byte we served.  -1 means nothing served yet.
  int _lastServedEnd = -1;

  /// Bumped on every detected seek so stale debounce timers self-cancel.
  int _seekGeneration = 0;

  /// Separate generation for cache trims so seeks and trims don't cancel each other.
  int _trimGeneration = 0;

  // ── Public entry point ───────────────────────────────────────────────────

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
    String? expectedFileUniqueId,
    required String mediaTitle,
    required String displayTitle,
    String releaseYear = '',
    bool isSeriesMedia = false,
    int? season,
    int? episode,
    String? quality,
    String? mimeType,
    int? fileSize,
    Future<void> Function(ResolvedTelegramMediaFile resolved)?
        onLocatorResolved,
    void Function(String message)? onStatus,
  }) async {
    _lastOpenFailureReason = null;
    _playbackEpoch++;
    await _stopLoopbackServerIfAny();

    final prevTd = _tdlib;
    final prevFileId = _activeFileId;
    if (prevTd != null && prevFileId != null) {
      await _cancelAndDelete(tdlib: prevTd, fileId: prevFileId);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));

    _tdlib = tdlib;
    _activeFileId = null;
    _activeLocalPath = null;
    _activeTotalBytes = 0;
    _downloadOffset = 0;
    _downloadPrefixSize = 0;
    _downloadedSize = 0;
    _lastPokeOffset = -1;
    _lastPokeAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastServedEnd = -1;
    _seekGeneration = 0;
    _trimGeneration = 0;
    _activeMime =
        (mimeType ?? '').trim().isEmpty ? 'video/*' : mimeType!.trim();

    final resolved = await resolveTelegramMediaFile(
      tdlib: tdlib,
      mediaFileId: (mediaFileId ?? '').trim().isNotEmpty
          ? mediaFileId!.trim()
          : variantId,
      telegramFileId: telegramFileId,
      locatorType: locatorType,
      locatorChatId: locatorChatId,
      locatorMessageId: locatorMessageId,
      locatorBotUsername: locatorBotUsername,
      locatorRemoteFileId: locatorRemoteFileId,
      expectedFileUniqueId: expectedFileUniqueId,
    );
    if (resolved == null) {
      _lastOpenFailureReason = 'resolve_failed';
      _keyLog('OPEN FAILED reason=$_lastOpenFailureReason');
      return null;
    }
    _keyLog(
      'OPEN RESOLVED locatorType=${resolved.locatorType} '
      'locatorChatId=${resolved.locatorChatId} locatorMessageId=${resolved.locatorMessageId} '
      'resolvedFileId=${resolved.file.id}',
    );
    _locatorLog(
      'OPEN RESOLVED locatorType=${resolved.locatorType} '
      'locatorChatId=${resolved.locatorChatId} locatorMessageId=${resolved.locatorMessageId} '
      'resolvedFileId=${resolved.file.id} reason=${resolved.resolutionReason}',
    );
    if (onLocatorResolved != null) {
      try {
        await onLocatorResolved(resolved);
      } catch (_) {}
    }
    final tdFile = resolved.file;

    _activeFileId = tdFile.id;
    _activeLocalPath =
        tdFile.local.path.trim().isEmpty ? null : tdFile.local.path.trim();
    var best = 0;
    if (fileSize != null && fileSize > best) best = fileSize;
    if (tdFile.expectedSize > best) best = tdFile.expectedSize;
    if (tdFile.size > best) best = tdFile.size;
    _activeTotalBytes = best;

    await _maybeRunLowStorageCleanup(onStatus: onStatus);

    _keyLog(
        'OPEN fileId=$_activeFileId total=${(_activeTotalBytes / (1024 * 1024)).toStringAsFixed(1)}MB');

    try {
      await _download(offset: 0, bytes: _kChunkBytes, synchronous: true)
          .timeout(_kSyncTdlibDownloadTimeout);
    } on TimeoutException {
      _keyLog(
          'OPEN sync bootstrap TIMEOUT ${_kSyncTdlibDownloadTimeout.inSeconds}s → async');
      await _download(offset: 0, bytes: _kChunkBytes, synchronous: false);
    }
    if (!await _waitForPath(const Duration(seconds: 20))) {
      _keyLog('OPEN FAILED – path not ready after 20s');
      _lastOpenFailureReason = 'tdlib_path_timeout';
      return null;
    }

    await _ensureServer();
    final port = _server?.port;
    if (port == null) {
      _lastOpenFailureReason = 'loopback_server_failed';
      _keyLog('OPEN FAILED reason=$_lastOpenFailureReason');
      return null;
    }
    _keyLog('OPEN OK port=$port');
    return Uri.parse('http://127.0.0.1:$port/stream');
  }

  // ── HTTP server ──────────────────────────────────────────────────────────

  Future<void> _stopLoopbackServerIfAny() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    try {
      await server.close(force: true);
    } catch (e) {
      _streamLog('RangePlayback: HttpServer.close failed: $e');
    }
  }

  bool _stalePlaybackEpoch(int epoch) => epoch != _playbackEpoch;

  Future<void> _ensureServer() async {
    if (_server != null) return;
    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_handleRequest);
    _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    _streamLog(
        'RangePlayback: started on ${_server!.address.host}:${_server!.port}');
  }

  Future<Response> _handleRequest(Request request) async {
    _streamLog(
      'RangePlayback: ${request.method} '
      'range="${request.headers[HttpHeaders.rangeHeader] ?? ''}"',
    );
    if (request.url.path != 'stream') return Response.notFound('not found');

    final playbackEpoch = _playbackEpoch;

    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) {
      return Response.internalServerError(body: 'not initialized');
    }
    final filePath = _activeLocalPath;
    if (filePath == null || filePath.isEmpty) {
      return Response.notFound('file not ready');
    }
    final file = File(filePath);
    if (!await file.exists()) return Response.notFound('file missing');

    final totalBytes =
        _activeTotalBytes > 0 ? _activeTotalBytes : await file.length();
    if (totalBytes <= 0) {
      return Response.internalServerError(body: 'unknown size');
    }

    if (request.method == 'HEAD') {
      if (_stalePlaybackEpoch(playbackEpoch)) {
        return Response(HttpStatus.serviceUnavailable, body: 'playback ended');
      }
      return Response.ok('', headers: {
        HttpHeaders.acceptRangesHeader: 'bytes',
        HttpHeaders.contentTypeHeader: _activeMime,
        HttpHeaders.contentLengthHeader: '$totalBytes',
      });
    }

    final hdr = request.headers[HttpHeaders.rangeHeader];
    final parsed = _parseRange(hdr, totalBytes);
    if (parsed == null) {
      return Response(HttpStatus.requestedRangeNotSatisfiable,
          headers: {'Content-Range': 'bytes */$totalBytes'});
    }

    var start = parsed.$1;
    var end = parsed.$2;
    if ((hdr != null && RegExp(r'^bytes=\d+-$').hasMatch(hdr.trim())) ||
        (end - start + 1) > _kChunkBytes) {
      final cap = start + _kChunkBytes - 1;
      if (cap < end) end = cap;
    }
    final want = end - start + 1;
    _streamLog('RangePlayback: need start=$start end=$end want=$want');

    if (_stalePlaybackEpoch(playbackEpoch)) {
      return Response(HttpStatus.serviceUnavailable, body: 'playback ended');
    }

    // ── Seek detection ─────────────────────────────────────────────────────
    final isSeek = _isSeek(start);
    if (isSeek) {
      _keyLog('SEEK to=${(start / (1024 * 1024)).toStringAsFixed(1)}MB '
          'from=${(_lastServedEnd / (1024 * 1024)).toStringAsFixed(1)}MB '
          'dlOff=${(_downloadOffset / (1024 * 1024)).toStringAsFixed(1)}MB');
      await _handleSeek(start);
    }

    if (_stalePlaybackEpoch(playbackEpoch)) {
      return Response(HttpStatus.serviceUnavailable, body: 'playback ended');
    }

    // ── Ensure data available ──────────────────────────────────────────────
    // Sequential reads: first downloadFile synchronous so TDLib commits ~4MiB
    // quickly. After a seek we already async-download from target — stay async.
    final syncFirstPoke = !isSeek;
    final wr = await _waitForRange(
      start,
      end,
      playbackEpoch: playbackEpoch,
      syncFirstPoke: syncFirstPoke,
      isSeek: isSeek,
    );
    final waitMs = wr.elapsedMs;
    if (wr.abortedStale) {
      return Response(HttpStatus.serviceUnavailable, body: 'playback ended');
    }
    if (!wr.ok) {
      final avail = wr.lastAvail;
      if (avail <= 0) {
        _keyLog('NO DATA → 416');
        return Response(HttpStatus.requestedRangeNotSatisfiable,
            headers: {'Content-Range': 'bytes */$totalBytes'});
      }
      final partialEnd = start + avail - 1;
      end = partialEnd < end ? partialEnd : end;
      _keyLog('PARTIAL ${(avail / 1024).toStringAsFixed(0)}KB');
    }

    // ── Read & respond ─────────────────────────────────────────────────────
    if (_stalePlaybackEpoch(playbackEpoch)) {
      return Response(HttpStatus.serviceUnavailable, body: 'playback ended');
    }
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(end - start + 1);
      _streamLog(
        'RangePlayback: 206 bytes=${bytes.length} '
        'range=$start-${start + bytes.length - 1}/$totalBytes',
      );
      _lastServedEnd = start + bytes.length - 1;
      _keyLog(
        'SERVED ${isSeek ? 'seek' : 'seq'} '
        '${(start / (1024 * 1024)).toStringAsFixed(2)}MB '
        '${(bytes.length / 1024).toStringAsFixed(0)}KB wait=${waitMs}ms',
      );
      _scheduleTrimIfNeeded();
      return Response(HttpStatus.partialContent, body: bytes, headers: {
        HttpHeaders.acceptRangesHeader: 'bytes',
        HttpHeaders.contentTypeHeader: _activeMime,
        HttpHeaders.contentLengthHeader: '${bytes.length}',
        HttpHeaders.contentRangeHeader:
            'bytes $start-${start + bytes.length - 1}/$totalBytes',
      });
    } finally {
      await raf.close();
    }
  }

  // ── Seek handling ────────────────────────────────────────────────────────

  bool _isSeek(int requestStart) {
    if (_lastServedEnd < 0) return false;
    final gap = (requestStart - (_lastServedEnd + 1)).abs();
    return gap > _kSeekThresholdBytes;
  }

  Future<void> _handleSeek(int newOffset) async {
    final aligned = (newOffset ~/ _kSeekAlignBytes) * _kSeekAlignBytes;
    _seekGeneration++;
    final nearEnd = _activeTotalBytes > 0 &&
        aligned + _kChunkBytes >= _activeTotalBytes - (512 * 1024);
    final farBody = aligned >= _kFarSeekSyncMinOffsetBytes;
    final useSyncBootstrap = farBody && !nearEnd;

    _keyLog(
      'SEEK DL off=${(newOffset / (1024 * 1024)).toStringAsFixed(2)}MB '
      'al=${(aligned / (1024 * 1024)).toStringAsFixed(2)}MB '
      'syncBoot=$useSyncBootstrap',
    );

    if (useSyncBootstrap) {
      final tBoot = DateTime.now();
      try {
        await _download(
          offset: aligned,
          bytes: _kFarSeekSyncBootstrapBytes,
          synchronous: true,
        ).timeout(_kSyncTdlibDownloadTimeout);
        _keyLog(
          'SEEK syncBoot done ms=${DateTime.now().difference(tBoot).inMilliseconds} '
          '${(_kFarSeekSyncBootstrapBytes / 1024).toStringAsFixed(0)}KB',
        );
      } on TimeoutException {
        _keyLog(
          'SEEK syncBoot TIMEOUT ${_kSyncTdlibDownloadTimeout.inSeconds}s '
          '(TDLib may still be busy) → async only',
        );
      }
    }

    await _download(
      offset: aligned,
      bytes: _kChunkBytes + _kPrefetchBytes,
      synchronous: false,
    );
  }

  /// TDLib downloads from [aligned] floor; [GetFileDownloadedPrefixSize] at exact
  /// [start] stays 0 until the contiguous run reaches [start]. Derive avail at
  /// [start] from prefix at [aligned] when [start] > [aligned].
  Future<int> _availAtRangeStart(int start, {required bool isSeek}) async {
    if (!isSeek) return _prefixFrom(start);
    final direct = await _prefixFrom(start);
    final aligned = (start ~/ _kSeekAlignBytes) * _kSeekAlignBytes;
    final preAligned = await _prefixFrom(aligned);
    final gap = start - aligned;
    final fromAligned = preAligned > gap ? preAligned - gap : 0;
    return direct > fromAligned ? direct : fromAligned;
  }

  // ── Wait for a byte range to become available ────────────────────────────

  Future<
      ({
        bool ok,
        bool abortedStale,
        int elapsedMs,
        int repokes,
        int lastAvail,
        int need
      })> _waitForRange(
    int start,
    int end, {
    required int playbackEpoch,
    required bool syncFirstPoke,
    required bool isSeek,
  }) async {
    final t0 = DateTime.now();
    final need = end - start + 1;
    final pokeOffset =
        isSeek ? (start ~/ _kSeekAlignBytes) * _kSeekAlignBytes : start;
    await _refreshLocal();
    var lastAvail = await _availAtRangeStart(start, isSeek: isSeek);

    final syncOk = syncFirstPoke &&
        (lastAvail >= _kMinPrefixBytesForSyncFirst || lastAvail >= need ~/ 2);
    _keyLog(
      'WAIT START start=${(start / (1024 * 1024)).toStringAsFixed(2)}MB '
      'need=${(need / 1024).toStringAsFixed(0)}KB wantSync=$syncFirstPoke '
      'syncEff=$syncOk pre=${(lastAvail / 1024).toStringAsFixed(0)}KB',
    );

    if (_stalePlaybackEpoch(playbackEpoch)) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      _keyLog(
          'WAIT ABORT stale epoch=$playbackEpoch now=$_playbackEpoch ms=$ms');
      return (
        ok: false,
        abortedStale: true,
        elapsedMs: ms,
        repokes: 0,
        lastAvail: lastAvail,
        need: need,
      );
    }

    if (lastAvail >= need) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      _keyLog(
          'WAIT END ok=1 ms=$ms repokes=0 avail=${(lastAvail / 1024).toStringAsFixed(0)}KB');
      return (
        ok: true,
        abortedStale: false,
        elapsedMs: ms,
        repokes: 0,
        lastAvail: lastAvail,
        need: need,
      );
    }

    if (syncOk) {
      try {
        await _download(
          offset: pokeOffset,
          bytes: _kChunkBytes + _kPrefetchBytes,
          synchronous: true,
        ).timeout(_kSyncTdlibDownloadTimeout);
      } on TimeoutException {
        _keyLog(
          'WAIT first sync TIMEOUT ${_kSyncTdlibDownloadTimeout.inSeconds}s → async',
        );
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
      final ms = DateTime.now().difference(t0).inMilliseconds;
      _keyLog('WAIT ABORT stale epoch=$playbackEpoch (post-poke) ms=$ms');
      return (
        ok: false,
        abortedStale: true,
        elapsedMs: ms,
        repokes: 0,
        lastAvail: lastAvail,
        need: need,
      );
    }

    var repokes = 0;
    var stallRecoverDone = false;
    final deadline = DateTime.now().add(_kWaitTimeout);
    var nextRepoke = DateTime.now().add(
      lastAvail < need ~/ 4 ? _kRepokeStarved : _kRepoke,
    );

    while (DateTime.now().isBefore(deadline)) {
      if (_stalePlaybackEpoch(playbackEpoch)) {
        final ms = DateTime.now().difference(t0).inMilliseconds;
        _keyLog('WAIT ABORT stale epoch=$playbackEpoch (loop) ms=$ms');
        return (
          ok: false,
          abortedStale: true,
          elapsedMs: ms,
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
        final facade = _tdlib;
        final fid = _activeFileId;
        if (facade != null && fid != null) {
          _keyLog(
              'WAIT STALL ${_kSeekStallRecoverAfter.inSeconds}s pre=0 → cancel+repoke');
          try {
            await facade
                .send(td.CancelDownloadFile(fileId: fid, onlyIfPending: false));
          } catch (_) {}
          await _download(
            offset: pokeOffset,
            bytes: _kChunkBytes + _kPrefetchBytes,
            synchronous: false,
          );
        }
      }
      if (lastAvail >= need) {
        final ms = DateTime.now().difference(t0).inMilliseconds;
        _keyLog(
          'WAIT END ok=1 ms=$ms repokes=$repokes '
          'avail=${(lastAvail / 1024).toStringAsFixed(0)}KB',
        );
        return (
          ok: true,
          abortedStale: false,
          elapsedMs: ms,
          repokes: repokes,
          lastAvail: lastAvail,
          need: need,
        );
      }

      if (isSeek && lastAvail >= _kSeekEarlyPartialMinBytes) {
        final elapsed = DateTime.now().difference(t0);
        if (elapsed >= _kSeekEarlyPartialAfter) {
          final ms = elapsed.inMilliseconds;
          _keyLog(
            'WAIT END ok=0 early=1 ms=$ms repokes=$repokes '
            'avail=${(lastAvail / 1024).toStringAsFixed(0)}KB',
          );
          return (
            ok: false,
            abortedStale: false,
            elapsedMs: ms,
            repokes: repokes,
            lastAvail: lastAvail,
            need: need,
          );
        }
      }

      final now = DateTime.now();
      if (now.isAfter(nextRepoke)) {
        nextRepoke = now.add(
          lastAvail < need ~/ 4 ? _kRepokeStarved : _kRepoke,
        );
        repokes++;
        await _download(
          offset: pokeOffset,
          bytes: _kChunkBytes + _kPrefetchBytes,
          synchronous: false,
        );
        if (repokes == 1 || repokes % 5 == 0) {
          _keyLog(
            'WAIT REPOKE #$repokes start=${(start / (1024 * 1024)).toStringAsFixed(2)}MB '
            'avail=${(lastAvail / 1024).toStringAsFixed(0)}KB',
          );
        }
      }
      await Future<void>.delayed(_kPollInterval);
    }

    final ms = DateTime.now().difference(t0).inMilliseconds;
    _keyLog(
      'WAIT END ok=0 ms=$ms repokes=$repokes '
      'lastAvail=${(lastAvail / 1024).toStringAsFixed(0)}KB need=${(need / 1024).toStringAsFixed(0)}KB',
    );
    return (
      ok: false,
      abortedStale: false,
      elapsedMs: ms,
      repokes: repokes,
      lastAvail: lastAvail,
      need: need,
    );
  }

  // ── Cache trim ───────────────────────────────────────────────────────────

  void _scheduleTrimIfNeeded() {
    if (_downloadedSize < _kMaxCacheBeforeTrimBytes) return;
    final playhead = _lastServedEnd;
    if (playhead <= 0) return;

    _trimGeneration++;
    final gen = _trimGeneration;
    final seekSnap = _seekGeneration;
    final epochSnap = _playbackEpoch;
    unawaited(Future<void>(() async {
      await Future<void>.delayed(
          const Duration(milliseconds: _kSeekDebounceMs));
      if (epochSnap != _playbackEpoch) return;
      if (gen != _trimGeneration) return;
      if (seekSnap != _seekGeneration) return;
      if (_downloadedSize < _kMaxCacheBeforeTrimBytes) return;
      await _trimCache(_lastServedEnd > 0 ? _lastServedEnd : playhead);
    }));
  }

  Future<void> _trimCache(int keepFromOffset) async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return;

    _keyLog(
        'TRIM delete+restart from=${(keepFromOffset / (1024 * 1024)).toStringAsFixed(1)}MB '
        'was=${_downloadedSize ~/ (1024 * 1024)}MB');

    try {
      await tdlib
          .send(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false));
    } catch (_) {}
    try {
      await tdlib.send(td.DeleteFile(fileId: fileId));
    } catch (_) {}

    await _refreshLocal();

    await _download(
      offset: keepFromOffset,
      bytes: _kChunkBytes + _kPrefetchBytes,
      synchronous: false,
    );
    await _refreshLocal();
  }

  // ── TDLib helpers ────────────────────────────────────────────────────────

  Future<void> _download({
    required int offset,
    required int bytes,
    bool synchronous = false,
  }) async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return;
    final limit = bytes > _kMaxTdlibLimit ? _kMaxTdlibLimit : bytes;
    final off = offset < 0 ? 0 : offset;
    final now = DateTime.now();
    // Keep short: repokes use 500ms when starved; 700ms was skipping most of them.
    if (!synchronous &&
        off == _lastPokeOffset &&
        now.difference(_lastPokeAt) < const Duration(milliseconds: 120)) {
      _streamLog('RangePlayback: skip duplicate download off=$off');
      return;
    }
    _lastPokeOffset = off;
    _lastPokeAt = now;
    try {
      await tdlib.send(td.DownloadFile(
        fileId: fileId,
        priority: 32,
        offset: off,
        limit: limit,
        synchronous: synchronous,
      ));
      _streamLog(
          'RangePlayback: download off=$off limit=$limit sync=$synchronous');
    } catch (_) {}
  }

  Future<int> _prefixFrom(int offset) async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return 0;
    if (offset < 0) return 0;
    try {
      final obj = await tdlib
          .send(td.GetFileDownloadedPrefixSize(fileId: fileId, offset: offset));
      if (obj is td.FileDownloadedPrefixSize) return obj.size;
    } catch (_) {}

    if (_downloadPrefixSize > 0) {
      final a0 = _downloadOffset;
      final a1 = a0 + _downloadPrefixSize - 1;
      if (offset >= a0 && offset <= a1) return a1 - offset + 1;
    }
    return 0;
  }

  Future<void> _refreshLocal() async {
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return;
    try {
      final obj = await tdlib.send(td.GetFile(fileId: fileId));
      if (obj is! td.File) return;
      final p = obj.local.path.trim();
      if (p.isNotEmpty) _activeLocalPath = p;
      _downloadedSize = obj.local.downloadedSize;
      _downloadOffset = obj.local.downloadOffset;
      _downloadPrefixSize = obj.local.downloadedPrefixSize;
      if (_activeTotalBytes <= 0) {
        _activeTotalBytes = obj.expectedSize > 0 ? obj.expectedSize : obj.size;
      }
    } catch (_) {}
  }

  Future<bool> _waitForPath(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final dl = await _refreshLocalAndReturnSize();
      final path = (_activeLocalPath ?? '').trim();
      if (path.isNotEmpty && dl > 0) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<int> _refreshLocalAndReturnSize() async {
    await _refreshLocal();
    return _downloadedSize;
  }

  Future<void> _cancelAndDelete({
    required TdlibFacade tdlib,
    required int fileId,
  }) async {
    try {
      await tdlib
          .send(td.CancelDownloadFile(fileId: fileId, onlyIfPending: false));
    } catch (_) {}
    try {
      await tdlib.send(td.DeleteFile(fileId: fileId));
    } catch (_) {}
    _streamLog('RangePlayback: released cache fileId=$fileId');
  }

  Future<int> releaseActiveCacheIfAny({String reason = 'manual'}) async {
    _playbackEpoch++;
    await _stopLoopbackServerIfAny();
    final tdlib = _tdlib;
    final fileId = _activeFileId;
    if (tdlib == null || fileId == null) return 0;
    _keyLog('CACHE RELEASE reason=$reason fileId=$fileId');
    await _cancelAndDelete(tdlib: tdlib, fileId: fileId);
    _activeFileId = null;
    _activeLocalPath = null;
    _downloadOffset = 0;
    _downloadPrefixSize = 0;
    _downloadedSize = 0;
    _lastServedEnd = -1;
    return 1;
  }

  Future<void> _maybeRunLowStorageCleanup({
    void Function(String message)? onStatus,
  }) async {
    final decision = await queryStorageCleanupDecision();
    if (!decision.cleanupMode) return;
    final freeText = decision.freeBytes == null
        ? 'unknown'
        : '${(decision.freeBytes! / (1024 * 1024)).toStringAsFixed(0)}MB';
    _keyLog('LOW STORAGE free=$freeText cleanup=1');
    onStatus?.call('Low storage detected. Cleaning cache...');
    await releaseActiveCacheIfAny(reason: 'low_storage_stream_start');
    await Future<void>.delayed(kStorageCleanupPause);
    onStatus?.call('Cache cleanup done. Continuing playback...');
  }

  // ── Range parsing ────────────────────────────────────────────────────────

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
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) {
      final suffix = int.tryParse(b);
      if (suffix == null || suffix <= 0) return null;
      if (suffix >= totalBytes) return (0, maxEnd);
      return (totalBytes - suffix, maxEnd);
    }
    final start = int.tryParse(a) ?? -1;
    if (start < 0 || start >= totalBytes) return null;
    int end;
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

