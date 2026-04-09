import 'dart:async';

import 'package:tdlib/td_api.dart' as td;

import 'tdlib_facade.dart';

const Duration _kResolveSendTimeout = Duration(seconds: 8);
const Duration _kResolveOverallTimeout = Duration(seconds: 25);

class ResolvedTelegramMediaFile {
  const ResolvedTelegramMediaFile({
    required this.file,
    this.locatorChatId,
    this.locatorMessageId,
    this.locatorType,
    this.resolutionReason,
  });

  final td.File file;
  final int? locatorChatId;
  final int? locatorMessageId;
  final String? locatorType;
  final String? resolutionReason;
}

class _ExtractedFromMessage {
  const _ExtractedFromMessage({
    required this.file,
    required this.locatorMessageId,
  });

  final td.File file;
  final int locatorMessageId;
}

Future<ResolvedTelegramMediaFile?> resolveTelegramMediaFile({
  required TdlibFacade tdlib,
  required String mediaFileId,
  String? locatorType,
  int? locatorChatId,
  int? locatorMessageId,
  String? locatorBotUsername,
  String? locatorRemoteFileId,
}) {
  return _resolveTelegramMediaFileImpl(
    tdlib: tdlib,
    mediaFileId: mediaFileId,
    locatorType: locatorType,
    locatorChatId: locatorChatId,
    locatorMessageId: locatorMessageId,
    locatorBotUsername: locatorBotUsername,
    locatorRemoteFileId: locatorRemoteFileId,
  ).timeout(_kResolveOverallTimeout, onTimeout: () => null);
}

Future<ResolvedTelegramMediaFile?> _resolveTelegramMediaFileImpl({
  required TdlibFacade tdlib,
  required String mediaFileId,
  String? locatorType,
  int? locatorChatId,
  int? locatorMessageId,
  String? locatorBotUsername,
  String? locatorRemoteFileId,
}) async {
  if (locatorType == 'PRIVATE_USER_CHAT' &&
      locatorChatId != null &&
      locatorMessageId != null) {
    final privateChatId = await _resolvePrivateUserChatId(tdlib, locatorChatId);
    if (privateChatId != null) {
      final byPrivateMessage = await _resolveFileByMessage(
        tdlib: tdlib,
        chatId: privateChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: true,
      );
      if (byPrivateMessage != null) {
        return ResolvedTelegramMediaFile(
          file: byPrivateMessage.file,
          locatorChatId: privateChatId,
          locatorMessageId: byPrivateMessage.locatorMessageId,
          locatorType: 'CHAT_MESSAGE',
          resolutionReason: 'direct_private_user_message',
        );
      }
    }
  }

  if (locatorType == 'BOT_PRIVATE_RUNTIME' &&
      (locatorBotUsername ?? '').trim().isNotEmpty &&
      locatorMessageId != null) {
    final runtimeChatId =
        await _resolveBotPrivateChatId(tdlib, locatorBotUsername!.trim());
    if (runtimeChatId != null) {
      final byRuntimeMessage = await _resolveFileByMessage(
        tdlib: tdlib,
        chatId: runtimeChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: true,
      );
      if (byRuntimeMessage != null) {
        return ResolvedTelegramMediaFile(
          file: byRuntimeMessage.file,
          locatorChatId: runtimeChatId,
          locatorMessageId: byRuntimeMessage.locatorMessageId,
          locatorType: 'CHAT_MESSAGE',
          resolutionReason: 'direct_runtime_message',
        );
      }
    }
  }

  if (locatorType == 'CHAT_MESSAGE' &&
      locatorMessageId != null) {
    _ExtractedFromMessage? byMessage;
    if (locatorChatId != null) {
      byMessage = await _resolveFileByMessage(
        tdlib: tdlib,
        chatId: locatorChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: false,
      );
    }
    if (byMessage != null) {
      return ResolvedTelegramMediaFile(
        file: byMessage.file,
        locatorChatId: locatorChatId,
        locatorMessageId: byMessage.locatorMessageId,
        locatorType: 'CHAT_MESSAGE',
        resolutionReason: 'direct_chat_message',
      );
    }

    final trimmedBotUsername = locatorBotUsername?.trim() ?? '';
    if (trimmedBotUsername.isNotEmpty) {
      final runtimeChatId = await _resolveBotPrivateChatId(tdlib, trimmedBotUsername);
      if (runtimeChatId != null) {
        final byRuntimeMessage = await _resolveFileByMessage(
          tdlib: tdlib,
          chatId: runtimeChatId,
          messageId: locatorMessageId,
          exactChatIdOnly: true,
        );
        if (byRuntimeMessage != null) {
          return ResolvedTelegramMediaFile(
            file: byRuntimeMessage.file,
            locatorChatId: runtimeChatId,
            locatorMessageId: byRuntimeMessage.locatorMessageId,
            locatorType: 'CHAT_MESSAGE',
            resolutionReason: 'fallback_runtime_message',
          );
        }
      }
    }
  }

  final trimmedLocatorRemote = locatorRemoteFileId?.trim() ?? '';
  if (trimmedLocatorRemote.isNotEmpty) {
    try {
      final remoteFile = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.GetRemoteFile(
          remoteFileId: trimmedLocatorRemote,
          fileType: null,
        ),
      );
      if (remoteFile is td.File) {
        return ResolvedTelegramMediaFile(
          file: remoteFile,
          locatorType: 'REMOTE_FILE_ID',
          resolutionReason: 'get_remote_file_locator_remote',
        );
      }
    } catch (_) {}
  }

  return null;
}

Future<_ExtractedFromMessage?> _resolveFileByMessage({
  required TdlibFacade tdlib,
  required int chatId,
  required int messageId,
  required bool exactChatIdOnly,
}) async {
  for (final chatCandidate in _candidateTelegramChatIds(chatId, exactOnly: exactChatIdOnly)) {
    for (final messageCandidate in _candidateTelegramMessageIds(messageId)) {
      try {
        final messageObject = await _sendWithTimeout(
          tdlib: tdlib,
          request: td.GetMessage(
            chatId: chatCandidate,
            messageId: messageCandidate,
          ),
        );
        if (messageObject is! td.Message) continue;
        final file = _extractFileFromMessage(messageObject);
        if (file == null) continue;
        return _ExtractedFromMessage(
          file: file,
          locatorMessageId: messageObject.id,
        );
      } catch (_) {}
    }
  }

  return null;
}

Future<int?> _resolveBotPrivateChatId(
  TdlibFacade tdlib,
  String botUsername,
) async {
  final cleaned = botUsername.trim().replaceFirst(RegExp(r'^@'), '');
  if (cleaned.isEmpty) return null;

  try {
    final resolved = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.SearchPublicChat(username: cleaned),
    );
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      return null;
    }

    final botUserId = (resolved.type as td.ChatTypePrivate).userId;
    final privateChat = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.CreatePrivateChat(userId: botUserId, force: false),
    );
    if (privateChat is td.Chat) {
      try {
        await _sendWithTimeout(
          tdlib: tdlib,
          request: td.OpenChat(chatId: privateChat.id),
        );
      } catch (_) {}
      return privateChat.id;
    }
  } catch (_) {}

  return null;
}

Future<int?> _resolvePrivateUserChatId(
  TdlibFacade tdlib,
  int userId,
) async {
  if (userId <= 0) return null;

  try {
    final privateChat = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.CreatePrivateChat(userId: userId, force: false),
    );
    if (privateChat is td.Chat) {
      try {
        await _sendWithTimeout(
          tdlib: tdlib,
          request: td.OpenChat(chatId: privateChat.id),
        );
      } catch (_) {}
      return privateChat.id;
    }
  } catch (_) {}

  return null;
}

Future<td.TdObject> _sendWithTimeout({
  required TdlibFacade tdlib,
  required td.TdFunction request,
}) {
  return tdlib.send(request).timeout(_kResolveSendTimeout);
}

Iterable<int> _candidateTelegramChatIds(int chatId, {bool exactOnly = false}) sync* {
  final emitted = <int>{};

  bool emit(int value) {
    if (value == 0 || emitted.contains(value)) return false;
    emitted.add(value);
    return true;
  }

  if (emit(chatId)) yield chatId;

  if (exactOnly) return;

  if (chatId > 0 && emit(-chatId)) yield -chatId;

  const supergroupPrefix = 1000000000000;
  if (chatId > 0) {
    final supergroupChatId = -(supergroupPrefix + chatId);
    if (emit(supergroupChatId)) yield supergroupChatId;
  }
}

Iterable<int> _candidateTelegramMessageIds(int messageId) sync* {
  yield messageId;

  final tdlibScaled = messageId * 1048576;
  if (tdlibScaled != messageId) {
    yield tdlibScaled;
  }
}

td.File? _extractFileFromMessage(td.Message message) {
  final content = message.content;
  if (content is td.MessageVideo) return content.video.video;
  if (content is td.MessageDocument) return content.document.document;
  if (content is td.MessageAnimation) return content.animation.animation;
  if (content is td.MessageVideoNote) return content.videoNote.video;
  return null;
}
