import 'dart:typed_data';

/// Contract implemented by the TDLib layer: range reads for Telegram documents.
///
/// Wire this to TDLib (`downloadFile` / `readFilePart` / streaming APIs) so
/// [TelegramRangePlayback] can expose an HTTP Range endpoint to `media_kit`.
/// Use **512 KiB-aligned** offsets where TDLib requires them; the loopback server
/// aligns HTTP Range requests before calling [readRange].
abstract class TelegramChunkReader {
  Future<int> totalBytes();

  Future<Uint8List> readRange(int offset, int length);

  String get mimeType;
}
