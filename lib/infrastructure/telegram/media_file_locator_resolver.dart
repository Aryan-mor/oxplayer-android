import 'dart:async';

import 'package:tdlib/td_api.dart' as td;

import 'tdlib_facade.dart';

const Duration _kResolveSendTimeout = Duration(seconds: 8);
const Duration _kResolveOverallTimeout = Duration(seconds: 25);
const String _kMediaLocatorSearchTagPrefix = '#oxm_';

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
    required this.resolutionReason,
    required this.resolvedChatId,
  });

  final td.File file;
  final int locatorMessageId;
  final String resolutionReason;
  final int resolvedChatId;
}

Future<ResolvedTelegramMediaFile?> resolveTelegramMediaFile({
  required TdlibFacade tdlib,
  required String mediaFileId,
  String? fileUniqueId,
  String? locatorType,
  int? locatorChatId,
  int? locatorMessageId,
  String? locatorRemoteFileId,
  void Function(String message)? onDiagnostic,
}) {
  return _resolveTelegramMediaFileImpl(
    tdlib: tdlib,
    mediaFileId: mediaFileId,
    fileUniqueId: fileUniqueId,
    locatorType: locatorType,
    locatorChatId: locatorChatId,
    locatorMessageId: locatorMessageId,
    locatorRemoteFileId: locatorRemoteFileId,
    onDiagnostic: onDiagnostic,
  ).timeout(
    _kResolveOverallTimeout,
    onTimeout: () {
      onDiagnostic?.call('Telegram media resolution timed out for mediaFileId=$mediaFileId');
      return null;
    },
  );
}

Future<ResolvedTelegramMediaFile?> _resolveTelegramMediaFileImpl({
  required TdlibFacade tdlib,
  required String mediaFileId,
  String? fileUniqueId,
  String? locatorType,
  int? locatorChatId,
  int? locatorMessageId,
  String? locatorRemoteFileId,
  void Function(String message)? onDiagnostic,
}) async {
  if (locatorType == 'CHAT_MESSAGE' &&
      locatorChatId != null &&
      locatorMessageId != null) {
    final chatCandidates = _candidateTelegramChatIds(locatorChatId, exactOnly: false)
        .toList(growable: false);
    final messageCandidates = _candidateTelegramMessageIds(locatorMessageId)
        .toList(growable: false);
    onDiagnostic?.call(
      'Stored locator direct lookup prepared for mediaFileId=$mediaFileId chatCandidates=$chatCandidates messageCandidates=$messageCandidates locatorRemoteFileId=$locatorRemoteFileId',
    );
    _ExtractedFromMessage? byMessage;
    byMessage = await _resolveFileByMessage(
      tdlib: tdlib,
      mediaFileId: mediaFileId,
      chatId: locatorChatId,
      messageId: locatorMessageId,
      fileUniqueId: fileUniqueId,
      exactChatIdOnly: false,
      onDiagnostic: onDiagnostic,
    );
    if (byMessage != null) {
      if (byMessage.resolutionReason == 'recent_history_file_unique_id') {
        onDiagnostic?.call(
          'Stored locator direct lookup did not resolve exact message for mediaFileId=$mediaFileId. History fallback recovered resolvedChatId=${byMessage.resolvedChatId} resolvedMessageId=${byMessage.locatorMessageId} requestedChatId=$locatorChatId requestedMessageId=$locatorMessageId fileId=${byMessage.file.id}',
        );
      } else if (byMessage.locatorMessageId != locatorMessageId ||
          byMessage.resolvedChatId != locatorChatId) {
        onDiagnostic?.call(
          'Stored locator direct lookup resolved with alternate candidate for mediaFileId=$mediaFileId requestedChatId=$locatorChatId requestedMessageId=$locatorMessageId resolvedChatId=${byMessage.resolvedChatId} resolvedMessageId=${byMessage.locatorMessageId} reason=${byMessage.resolutionReason} fileId=${byMessage.file.id}',
        );
      } else {
        onDiagnostic?.call(
          'Stored locator direct lookup resolved exact message for mediaFileId=$mediaFileId chatId=$locatorChatId messageId=$locatorMessageId fileId=${byMessage.file.id}',
        );
      }
      return ResolvedTelegramMediaFile(
        file: byMessage.file,
        locatorChatId: byMessage.resolvedChatId,
        locatorMessageId: byMessage.locatorMessageId,
        locatorType: 'CHAT_MESSAGE',
        resolutionReason: byMessage.resolutionReason,
      );
    }

    onDiagnostic?.call(
      'Stored locator direct lookup exhausted for mediaFileId=$mediaFileId requestedChatId=$locatorChatId requestedMessageId=$locatorMessageId fileUniqueId=$fileUniqueId',
    );
  }

  final trimmedLocatorRemote = locatorRemoteFileId?.trim() ?? '';
  if (trimmedLocatorRemote.isNotEmpty) {
    try {
      onDiagnostic?.call(
        'Trying Telegram remote file fallback for mediaFileId=$mediaFileId remoteFileId=$trimmedLocatorRemote',
      );
      final remoteFile = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.GetRemoteFile(
          remoteFileId: trimmedLocatorRemote,
          fileType: null,
        ),
      );
      if (remoteFile is td.File) {
        onDiagnostic?.call(
          'Telegram remote file fallback succeeded for mediaFileId=$mediaFileId fileId=${remoteFile.id}',
        );
        return ResolvedTelegramMediaFile(
          file: remoteFile,
          locatorType: 'REMOTE_FILE_ID',
          resolutionReason: 'get_remote_file_locator_remote',
        );
      }
      onDiagnostic?.call(
        'Telegram remote file fallback returned ${remoteFile.runtimeType} for mediaFileId=$mediaFileId',
      );
    } on td.TdError catch (error) {
      onDiagnostic?.call(
        'Telegram remote file fallback failed for mediaFileId=$mediaFileId: code=${error.code} message=${error.message}',
      );
    } catch (error) {
      onDiagnostic?.call(
        'Telegram remote file fallback crashed for mediaFileId=$mediaFileId: $error',
      );
    }
  }

  return null;
}

Future<_ExtractedFromMessage?> _resolveFileByMessage({
  required TdlibFacade tdlib,
  required String mediaFileId,
  required int chatId,
  required int messageId,
  String? fileUniqueId,
  required bool exactChatIdOnly,
  void Function(String message)? onDiagnostic,
}) async {
  final requestedMessageId = messageId;
  for (final chatCandidate in _candidateTelegramChatIds(chatId, exactOnly: exactChatIdOnly)) {
    for (final messageCandidate in _candidateTelegramMessageIds(messageId)) {
      try {
        onDiagnostic?.call(
          'Trying Telegram message lookup chatCandidate=$chatCandidate messageCandidate=$messageCandidate',
        );
        final messageObject = await _sendWithTimeout(
          tdlib: tdlib,
          request: td.GetMessage(
            chatId: chatCandidate,
            messageId: messageCandidate,
          ),
        );
        if (messageObject is! td.Message) continue;
        final file = _extractFileFromMessage(messageObject);
        if (file == null) {
          onDiagnostic?.call(
            'Telegram message lookup succeeded but message ${messageObject.id} had no playable file',
          );
          continue;
        }
        onDiagnostic?.call(
          'Telegram message lookup succeeded for chatCandidate=$chatCandidate resolvedMessageId=${messageObject.id} fileId=${file.id}',
        );
        final resolutionReason =
            chatCandidate == chatId && messageCandidate == requestedMessageId
            ? 'direct_chat_message_exact'
            : 'direct_chat_message_candidate';
        return _ExtractedFromMessage(
          file: file,
          locatorMessageId: messageObject.id,
          resolutionReason: resolutionReason,
          resolvedChatId: chatCandidate,
        );
      } on td.TdError catch (error) {
        onDiagnostic?.call(
          'Telegram message lookup failed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: code=${error.code} message=${error.message}',
        );
      } catch (error) {
        onDiagnostic?.call(
          'Telegram message lookup crashed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: $error',
        );
      }
    }

    final trimmedFileUniqueId = fileUniqueId?.trim() ?? '';
    if (trimmedFileUniqueId.isEmpty) {
      continue;
    }

    try {
      onDiagnostic?.call(
        'Trying Telegram recent history fallback for chatCandidate=$chatCandidate fileUniqueId=$trimmedFileUniqueId',
      );
      final history = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.GetChatHistory(
          chatId: chatCandidate,
          fromMessageId: 0,
          offset: 0,
          limit: 60,
          onlyLocal: false,
        ),
      );
      if (history is td.Messages) {
        for (final message in history.messages) {
          if (_messageFileUniqueId(message) != trimmedFileUniqueId) continue;
          final file = _extractFileFromMessage(message);
          if (file == null) continue;
          onDiagnostic?.call(
            'Telegram recent history fallback matched chatCandidate=$chatCandidate resolvedMessageId=${message.id} fileId=${file.id}',
          );
          return _ExtractedFromMessage(
            file: file,
            locatorMessageId: message.id,
            resolutionReason: 'recent_history_file_unique_id',
            resolvedChatId: chatCandidate,
          );
        }
        onDiagnostic?.call(
          'Telegram recent history fallback found no matching fileUniqueId for chatCandidate=$chatCandidate',
        );
      }
    } on td.TdError catch (error) {
      onDiagnostic?.call(
        'Telegram recent history fallback failed for chatCandidate=$chatCandidate: code=${error.code} message=${error.message}',
      );
    } catch (error) {
      onDiagnostic?.call(
        'Telegram recent history fallback crashed for chatCandidate=$chatCandidate: $error',
      );
    }

    final tagMatch = await _findMessageBySearchTagReply(
      tdlib: tdlib,
      mediaFileId: mediaFileId,
      chatId: chatCandidate,
      fileUniqueId: fileUniqueId,
      onDiagnostic: onDiagnostic,
    );
    if (tagMatch != null) {
      return tagMatch;
    }
  }

  return null;
}

Future<_ExtractedFromMessage?> _findMessageBySearchTagReply({
  required TdlibFacade tdlib,
  required String mediaFileId,
  required int chatId,
  String? fileUniqueId,
  void Function(String message)? onDiagnostic,
}) async {
  final query = _buildMediaLocatorSearchTag(mediaFileId);
  try {
    onDiagnostic?.call(
      'Trying Telegram bot reply search fallback for chatCandidate=$chatId query=$query',
    );
    final result = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.SearchChatMessages(
        chatId: chatId,
        query: query,
        senderId: null,
        fromMessageId: 0,
        offset: 0,
        limit: 20,
        filter: null,
        messageThreadId: 0,
      ),
    );
    if (result is! td.Messages || result.messages.isEmpty) {
      onDiagnostic?.call(
        'Telegram bot reply search fallback found no tag messages for chatCandidate=$chatId query=$query',
      );
      return null;
    }

    final trimmedFileUniqueId = fileUniqueId?.trim() ?? '';
    for (final tagMessage in result.messages) {
      final tagMessageFile = _extractFileFromMessage(tagMessage);
      if (tagMessageFile != null) {
        if (trimmedFileUniqueId.isNotEmpty && _messageFileUniqueId(tagMessage) != trimmedFileUniqueId) {
          onDiagnostic?.call(
            'Telegram bot reply search fallback skipped tagMessageId=${tagMessage.id} because direct message fileUniqueId did not match',
          );
        } else {
          onDiagnostic?.call(
            'Telegram bot reply search fallback matched direct tagMessageId=${tagMessage.id} resolvedChatId=$chatId resolvedMessageId=${tagMessage.id} fileId=${tagMessageFile.id}',
          );
          return _ExtractedFromMessage(
            file: tagMessageFile,
            locatorMessageId: tagMessage.id,
            resolutionReason: 'bot_reply_search_tag_direct_message',
            resolvedChatId: chatId,
          );
        }
      }

      final replyTo = tagMessage.replyTo;
      if (replyTo is! td.MessageReplyToMessage) continue;
      onDiagnostic?.call(
        'Telegram bot reply search fallback inspecting tagMessageId=${tagMessage.id} replyChatId=${replyTo.chatId} replyMessageId=${replyTo.messageId}',
      );
      try {
        final replied = await _sendWithTimeout(
          tdlib: tdlib,
          request: td.GetMessage(
            chatId: replyTo.chatId,
            messageId: replyTo.messageId,
          ),
        );
        if (replied is! td.Message) continue;
        if (trimmedFileUniqueId.isNotEmpty && _messageFileUniqueId(replied) != trimmedFileUniqueId) {
          onDiagnostic?.call(
            'Telegram bot reply search fallback skipped replyMessageId=${replyTo.messageId} because fileUniqueId did not match',
          );
          continue;
        }
        final file = _extractFileFromMessage(replied);
        if (file == null) continue;
        onDiagnostic?.call(
          'Telegram bot reply search fallback matched tagMessageId=${tagMessage.id} resolvedChatId=${replyTo.chatId} resolvedMessageId=${replied.id} fileId=${file.id}',
        );
        return _ExtractedFromMessage(
          file: file,
          locatorMessageId: replied.id,
          resolutionReason: 'bot_reply_search_tag',
          resolvedChatId: replyTo.chatId,
        );
      } on td.TdError catch (error) {
        onDiagnostic?.call(
          'Telegram bot reply search fallback failed for replyChatId=${replyTo.chatId} replyMessageId=${replyTo.messageId}: code=${error.code} message=${error.message}',
        );
      } catch (error) {
        onDiagnostic?.call(
          'Telegram bot reply search fallback crashed for replyChatId=${replyTo.chatId} replyMessageId=${replyTo.messageId}: $error',
        );
      }
    }
  } on td.TdError catch (error) {
    onDiagnostic?.call(
      'Telegram bot reply search fallback failed for chatCandidate=$chatId query=$query: code=${error.code} message=${error.message}',
    );
  } catch (error) {
    onDiagnostic?.call(
      'Telegram bot reply search fallback crashed for chatCandidate=$chatId query=$query: $error',
    );
  }

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

Iterable<int> _candidateTelegramMessageIds(
  int messageId,
) sync* {
  final tdlibScaled = messageId * 1048576;
  yield messageId;
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

String _buildMediaLocatorSearchTag(String mediaFileId) {
  return '$_kMediaLocatorSearchTagPrefix${mediaFileId.trim()}';
}

String? _messageFileUniqueId(td.Message message) {
  final content = message.content;
  if (content is td.MessageVideo) {
    final value = content.video.video.remote.uniqueId.trim();
    return value.isEmpty ? null : value;
  }
  if (content is td.MessageDocument) {
    final value = content.document.document.remote.uniqueId.trim();
    return value.isEmpty ? null : value;
  }
  if (content is td.MessageAnimation) {
    final value = content.animation.animation.remote.uniqueId.trim();
    return value.isEmpty ? null : value;
  }
  if (content is td.MessageVideoNote) {
    final value = content.videoNote.video.remote.uniqueId.trim();
    return value.isEmpty ? null : value;
  }
  return null;
}
