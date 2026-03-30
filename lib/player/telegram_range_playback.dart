import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../telegram/telegram_chunk_reader.dart';

/// TDLib file reads are expected on **512 KiB-aligned** offsets; we align Range
/// requests and full-file reads before calling [TelegramChunkReader.readRange].
const int kTdlibReadAlignment = 512 * 1024;

/// Bridges TDLib byte-range reads to `libmpv` via a loopback HTTP server.
///
/// This replaces the legacy Service Worker range bridge from `tv-app-old`.
class TelegramRangePlayback {
  TelegramRangePlayback._({
    required this.server,
    required this.uri,
    required this.player,
  });

  final HttpServer server;
  final Uri uri;
  final Player player;

  static Future<TelegramRangePlayback> open({
    required TelegramChunkReader reader,
    Player? player,
  }) async {
    final p = player ?? Player();
    final total = await reader.totalBytes();
    if (total <= 0) {
      throw StateError('Invalid Telegram file size ($total).');
    }

    Future<Uint8List> readAlignedSlice(int start, int endInclusive) async {
      final length = endInclusive - start + 1;
      final alignedStart = (start ~/ kTdlibReadAlignment) * kTdlibReadAlignment;
      var alignedEndExclusive = ((endInclusive + 1 + kTdlibReadAlignment - 1) ~/ kTdlibReadAlignment) * kTdlibReadAlignment;
      if (alignedEndExclusive > total) alignedEndExclusive = total;
      final readLen = alignedEndExclusive - alignedStart;
      final bytes = await reader.readRange(alignedStart, readLen);
      final skip = start - alignedStart;
      return bytes.sublist(skip, skip + length);
    }

    Future<Uint8List> readEntireFileAligned() async {
      final out = BytesBuilder(copy: false);
      var offset = 0;
      while (offset < total) {
        final len = offset + kTdlibReadAlignment > total ? total - offset : kTdlibReadAlignment;
        final part = await reader.readRange(offset, len);
        out.add(part);
        offset += len;
      }
      return out.takeBytes();
    }

    Future<shelf.Response> handle(shelf.Request request) async {
      if (request.method != 'GET' && request.method != 'HEAD') {
        return shelf.Response(405, body: 'Method Not Allowed');
      }

      final mime = reader.mimeType;
      final range = request.headers['range'];

      if (range == null || range.isEmpty) {
        if (request.method == 'HEAD') {
          return shelf.Response(
            200,
            headers: {
              'Content-Type': mime,
              'Content-Length': '$total',
              'Accept-Ranges': 'bytes',
            },
          );
        }
        final bytes = await readEntireFileAligned();
        return shelf.Response.ok(
          bytes,
          headers: {
            'Content-Type': mime,
            'Content-Length': '${bytes.length}',
            'Accept-Ranges': 'bytes',
          },
        );
      }

      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (match == null) {
        return shelf.Response(400, body: 'Bad Range');
      }
      final start = int.parse(match.group(1)!);
      final endStr = match.group(2);
      final end = (endStr != null && endStr.isNotEmpty) ? int.parse(endStr) : (total - 1);
      final clampedEnd = end.clamp(0, total - 1).toInt();
      final length = clampedEnd - start + 1;
      if (start < 0 || start >= total || length <= 0) {
        return shelf.Response(416, body: 'Range Not Satisfiable');
      }

      if (request.method == 'HEAD') {
        return shelf.Response(
          206,
          headers: {
            'Content-Type': mime,
            'Content-Length': '$length',
            'Content-Range': 'bytes $start-$clampedEnd/$total',
            'Accept-Ranges': 'bytes',
          },
        );
      }

      final chunk = await readAlignedSlice(start, clampedEnd);
      return shelf.Response(
        206,
        body: chunk,
        headers: {
          'Content-Type': mime,
          'Content-Length': '${chunk.length}',
          'Content-Range': 'bytes $start-$clampedEnd/$total',
          'Accept-Ranges': 'bytes',
        },
      );
    }

    final server = await shelf_io.serve(
      handle,
      InternetAddress.loopbackIPv4,
      0,
    );

    final uri = Uri.parse('http://127.0.0.1:${server.port}/stream');
    await p.open(Media(uri.toString()));

    return TelegramRangePlayback._(server: server, uri: uri, player: p);
  }

  Future<void> dispose() async {
    await player.dispose();
    await server.close(force: true);
  }
}
