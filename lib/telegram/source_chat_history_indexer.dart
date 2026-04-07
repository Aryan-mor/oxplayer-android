import 'package:tdlib/td_api.dart' as td;

import '../core/config/app_config.dart';
import '../data/api/oxplayer_api_service.dart';
import 'tdlib_facade.dart';

Map<String, dynamic>? _ingestItemFromMessage(td.Message m) {
  final c = m.content;
  if (c is td.MessageVideo) {
    final rid = c.video.video.remote.id.trim();
    if (rid.isEmpty) return null;
    final cap = c.caption.text.trim();
    return <String, dynamic>{
      'messageId': m.id,
      'remoteFileId': rid,
      'caption': cap.isEmpty ? null : cap,
      'messageDate':
          DateTime.fromMillisecondsSinceEpoch(m.date * 1000, isUtc: true)
              .toIso8601String(),
    };
  }
  if (c is td.MessageDocument) {
    final mt = c.document.mimeType.toLowerCase();
    if (!mt.startsWith('video/')) return null;
    final rid = c.document.document.remote.id.trim();
    if (rid.isEmpty) return null;
    final cap = c.caption.text.trim();
    return <String, dynamic>{
      'messageId': m.id,
      'remoteFileId': rid,
      'caption': cap.isEmpty ? null : cap,
      'messageDate':
          DateTime.fromMillisecondsSinceEpoch(m.date * 1000, isUtc: true)
              .toIso8601String(),
    };
  }
  return null;
}

/// Pulls video / video-document messages from TDLib and POSTs [/me/chats/.../ingest].
/// Stops when it reaches [lastIndexedMessageId] or history is exhausted.
Future<void> syncIndexedChatHistoryToApi({
  required TdlibFacade facade,
  required OxplayerApiService api,
  required AppConfig config,
  required String accessToken,
  required int tdChatId,
  required int telegramChatId,
  int? lastIndexedMessageId,
  int maxRounds = 30,
}) async {
  var fromMessageId = 0;
  var rounds = 0;
  var maxSeen = lastIndexedMessageId ?? 0;

  while (rounds < maxRounds) {
    rounds++;
    final obj = await facade.send(
      td.GetChatHistory(
        chatId: tdChatId,
        fromMessageId: fromMessageId,
        offset: 0,
        limit: 50,
        onlyLocal: false,
      ),
    );
    if (obj is! td.Messages || obj.messages.isEmpty) break;

    final batch = <Map<String, dynamic>>[];
    var shouldStop = false;

    final minId =
        obj.messages.map((m) => m.id).reduce((a, b) => a < b ? a : b);

    for (final m in obj.messages) {
      if (lastIndexedMessageId != null && m.id <= lastIndexedMessageId) {
        shouldStop = true;
        continue;
      }
      final row = _ingestItemFromMessage(m);
      if (row != null) batch.add(row);
      if (m.id > maxSeen) maxSeen = m.id;
    }

    if (batch.isNotEmpty) {
      await api.ingestSourceChatMessages(
        config: config,
        accessToken: accessToken,
        telegramChatId: telegramChatId,
        items: batch,
        lastIndexedMessageId: maxSeen > 0 ? maxSeen : null,
      );
    }

    if (shouldStop) break;

    if (minId == fromMessageId && fromMessageId != 0) break;
    fromMessageId = minId;
    if (obj.messages.length < 3) break;
  }
}
