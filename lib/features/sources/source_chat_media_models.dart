import '../../data/models/app_media.dart';
import '../../data/models/user_chat_dtos.dart';

AppMediaAggregate sourceChatRowToAggregate({
  required String telegramChatId,
  required SourceChatMediaRow row,
}) {
  final mediaId = 'td:$telegramChatId:${row.messageId}';
  final title = () {
    final c = row.caption?.trim();
    if (c != null && c.isNotEmpty) {
      final line = c.split('\n').first.trim();
      if (line.length > 120) return '${line.substring(0, 117)}…';
      return line;
    }
    return 'Video';
  }();
  final when = row.messageDate ?? DateTime.now();
  final media = AppMedia(
    id: mediaId,
    title: title,
    type: 'GENERAL_VIDEO',
    posterPath: null,
    createdAt: when,
    updatedAt: when,
  );
  final msgId = int.tryParse(row.messageId) ?? 0;
  final chatId = int.tryParse(telegramChatId) ?? 0;
  final file = AppMediaFile(
    id: row.fileId,
    mediaId: mediaId,
    fileUniqueId: (row.remoteFileId ?? '').trim().isNotEmpty
        ? row.remoteFileId!.trim()
        : row.fileId,
    canStream: true,
    captionText: row.caption?.trim(),
    locatorType: 'CHAT_MESSAGE',
    locatorChatId: chatId,
    locatorMessageId: msgId,
    telegramFileId: row.remoteFileId,
    createdAt: when,
    updatedAt: when,
  );
  return AppMediaAggregate(media: media, files: [file]);
}
