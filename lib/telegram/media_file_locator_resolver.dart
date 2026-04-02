import 'package:tdlib/td_api.dart' as td;

import '../core/debug/app_debug_log.dart';
import 'tdlib_facade.dart';

void _locatorLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

class ResolvedTelegramMediaFile {
  const ResolvedTelegramMediaFile({
    required this.file,
    this.locatorChatId,
    this.locatorMessageId,
    this.locatorType,
  });

  final td.File file;
  final int? locatorChatId;
  final int? locatorMessageId;
  final String? locatorType;
}

class _ExtractedFromMessage {
  const _ExtractedFromMessage({
    required this.file,
    required this.locatorMessageId,
  });

  final td.File file;
  final int locatorMessageId;
}

/// Global resolver for `mediaFileId -> td.File` used by stream/download flows.
///
/// Strategy:
/// 1) Try explicit locator / remote id from API.
/// 2) Search by caption tag in source/provider chats.
/// 3) Try `telegramFileId` as TDLib remote id.
/// 4) Optional fallback: ask provider bot to re-send then retry in provider chat.
Future<ResolvedTelegramMediaFile?> resolveTelegramMediaFile({
  required TdlibFacade tdlib,
  required String mediaFileId,
  required String indexTagForFileSearch,
  String? telegramFileId,
  int? sourceChatId,
  String? locatorType,
  int? locatorChatId,
  int? locatorMessageId,
  String? locatorBotUsername,
  String? locatorRemoteFileId,
  String? providerBotUsername,
  Future<bool> Function(String mediaFileId)? recoverFromBackup,
}) async {
  _locatorLog(
    'Locator: resolve start mediaFileId=$mediaFileId '
    'locatorType=$locatorType chat=$locatorChatId msg=$locatorMessageId',
  );

  if (locatorType == 'CHAT_MESSAGE' &&
      locatorChatId != null &&
      locatorMessageId != null) {
    final byMsg = await _resolveFileByMessage(
      tdlib: tdlib,
      chatId: locatorChatId,
      messageId: locatorMessageId,
    );
    if (byMsg != null) {
      return ResolvedTelegramMediaFile(
        file: byMsg.file,
        locatorChatId: locatorChatId,
        locatorMessageId: byMsg.locatorMessageId,
        locatorType: 'CHAT_MESSAGE',
      );
    }
  }

  if ((locatorRemoteFileId ?? '').trim().isNotEmpty) {
    try {
      final remoteFile = await tdlib.send(
        td.GetRemoteFile(
          remoteFileId: locatorRemoteFileId!.trim(),
          fileType: null,
        ),
      );
      if (remoteFile is td.File) {
        return ResolvedTelegramMediaFile(
          file: remoteFile,
          locatorType: 'REMOTE_FILE_ID',
        );
      }
    } catch (_) {}
  }

  if (sourceChatId != null) {
    final fromSource = await _resolveFileFromSourceChat(
      tdlib: tdlib,
      sourceChatId: sourceChatId,
      mediaFileId: mediaFileId,
      indexTagForFileSearch: indexTagForFileSearch,
    );
    if (fromSource != null) return fromSource;
  }

  if ((locatorBotUsername ?? '').trim().isNotEmpty) {
    final runtimeChatId = await _resolveBotPrivateChatId(tdlib, locatorBotUsername!.trim());
    if (runtimeChatId != null) {
      final fromBotChat = await _resolveFileFromSourceChat(
        tdlib: tdlib,
        sourceChatId: runtimeChatId,
        mediaFileId: mediaFileId,
        indexTagForFileSearch: indexTagForFileSearch,
      );
      if (fromBotChat != null) return fromBotChat;
    }
  }

  if ((providerBotUsername ?? '').trim().isNotEmpty) {
    final providerChatId = await _resolveBotPrivateChatId(tdlib, providerBotUsername!.trim());
    if (providerChatId != null) {
      final fromProviderChat = await _resolveFileFromSourceChat(
        tdlib: tdlib,
        sourceChatId: providerChatId,
        mediaFileId: mediaFileId,
        indexTagForFileSearch: indexTagForFileSearch,
      );
      if (fromProviderChat != null) return fromProviderChat;
    }
  }

  if ((telegramFileId ?? '').trim().isNotEmpty) {
    try {
      final remoteFile = await tdlib.send(
        td.GetRemoteFile(remoteFileId: telegramFileId!.trim(), fileType: null),
      );
      if (remoteFile is td.File) {
        return ResolvedTelegramMediaFile(
          file: remoteFile,
          locatorType: 'REMOTE_FILE_ID',
        );
      }
    } catch (e) {
      _locatorLog('Locator: GetRemoteFile(telegramFileId) failed: $e');
    }
  }

  if (recoverFromBackup != null) {
    bool recovered = false;
    try {
      recovered = await recoverFromBackup(mediaFileId);
    } catch (_) {
      recovered = false;
    }
    if (recovered && (providerBotUsername ?? '').trim().isNotEmpty) {
      final providerChatId = await _resolveBotPrivateChatId(tdlib, providerBotUsername!.trim());
      if (providerChatId != null) {
        final fromProviderAfterRecover = await _resolveFileFromSourceChat(
          tdlib: tdlib,
          sourceChatId: providerChatId,
          mediaFileId: mediaFileId,
          indexTagForFileSearch: indexTagForFileSearch,
        );
        if (fromProviderAfterRecover != null) return fromProviderAfterRecover;
      }
    }
  }

  return null;
}

Future<ResolvedTelegramMediaFile?> _resolveFileFromSourceChat({
  required TdlibFacade tdlib,
  required int sourceChatId,
  required String mediaFileId,
  required String indexTagForFileSearch,
}) async {
  final queries = _searchQueriesForMediaFileId(mediaFileId, indexTagForFileSearch);
  final seenMessageIds = <int>{};
  for (final query in queries) {
    final result = await tdlib.send(
      td.SearchChatMessages(
        chatId: sourceChatId,
        query: query,
        senderId: null,
        filter: null,
        messageThreadId: 0,
        fromMessageId: 0,
        offset: 0,
        limit: 20,
      ),
    );
    final messages = <td.Message>[];
    if (result is td.FoundChatMessages) {
      messages.addAll(result.messages);
    } else if (result is td.Messages) {
      messages.addAll(result.messages);
    }
    for (final msg in messages) {
      if (seenMessageIds.contains(msg.id)) continue;
      if (!_messageReferencesMediaFileId(msg, mediaFileId)) continue;
      seenMessageIds.add(msg.id);
      final direct = _extractFileFromMessage(msg);
      if (direct != null) {
        return ResolvedTelegramMediaFile(
          file: direct,
          locatorChatId: sourceChatId,
          locatorMessageId: msg.id,
          locatorType: 'CHAT_MESSAGE',
        );
      }
      final rt = msg.replyTo;
      if (rt is! td.MessageReplyToMessage) continue;
      try {
        final repliedObj =
            await tdlib.send(td.GetMessage(chatId: sourceChatId, messageId: rt.messageId));
        if (repliedObj is! td.Message) continue;
        final repliedFile = _extractFileFromMessage(repliedObj);
        if (repliedFile == null) continue;
        return ResolvedTelegramMediaFile(
          file: repliedFile,
          locatorChatId: sourceChatId,
          locatorMessageId: rt.messageId,
          locatorType: 'CHAT_MESSAGE',
        );
      } catch (_) {}
    }
  }
  return null;
}

Future<_ExtractedFromMessage?> _resolveFileByMessage({
  required TdlibFacade tdlib,
  required int chatId,
  required int messageId,
}) async {
  try {
    final msgObj = await tdlib.send(td.GetMessage(chatId: chatId, messageId: messageId));
    if (msgObj is! td.Message) return null;
    final direct = _extractFileFromMessage(msgObj);
    if (direct != null) {
      return _ExtractedFromMessage(file: direct, locatorMessageId: messageId);
    }
    final rt = msgObj.replyTo;
    if (rt is td.MessageReplyToMessage) {
      final repliedObj = await tdlib.send(td.GetMessage(chatId: chatId, messageId: rt.messageId));
      if (repliedObj is td.Message) {
        final repliedFile = _extractFileFromMessage(repliedObj);
        if (repliedFile != null) {
          return _ExtractedFromMessage(file: repliedFile, locatorMessageId: rt.messageId);
        }
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<int?> _resolveBotPrivateChatId(TdlibFacade tdlib, String botUsername) async {
  try {
    final resolved = await tdlib.send(td.SearchPublicChat(username: botUsername));
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) return null;
    final botUserId = (resolved.type as td.ChatTypePrivate).userId;
    final privateChat = await tdlib.send(td.CreatePrivateChat(userId: botUserId, force: false));
    if (privateChat is td.Chat) return privateChat.id;
  } catch (_) {}
  return null;
}

td.File? _extractFileFromMessage(td.Message msg) {
  final content = msg.content;
  if (content is td.MessageVideo) return content.video.video;
  if (content is td.MessageDocument) return content.document.document;
  if (content is td.MessageAnimation) return content.animation.animation;
  if (content is td.MessageVideoNote) return content.videoNote.video;
  return null;
}

bool _messageReferencesMediaFileId(td.Message msg, String mediaFileId) {
  final haystack = _flattenMessageCaptionAndText(msg);
  if (haystack.isEmpty) return false;
  final escaped = RegExp.escape(mediaFileId);
  return RegExp('_F_$escaped(?!\\d)').hasMatch(haystack);
}

String _flattenMessageCaptionAndText(td.Message msg) {
  final parts = <String>[];
  switch (msg.content) {
    case td.MessageText t:
      parts.add(t.text.text);
    case td.MessageVideo v:
      parts.add(v.caption.text);
    case td.MessageDocument d:
      parts.add(d.caption.text);
    case td.MessageAnimation a:
      parts.add(a.caption.text);
    default:
      break;
  }
  return parts.join('\n');
}

List<String> _searchQueriesForMediaFileId(
  String mediaFileId,
  String indexTagForFileSearch,
) {
  final q = <String>['_F_$mediaFileId'];
  final tag = indexTagForFileSearch.trim();
  if (tag.isNotEmpty) {
    final withHash = tag.startsWith('#') ? tag : '#$tag';
    q.add('${withHash}_F_$mediaFileId');
  }
  q.add(mediaFileId);
  return q;
}
