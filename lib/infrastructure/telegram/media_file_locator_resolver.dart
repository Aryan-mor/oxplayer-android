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
  /// TDLib chat ids (e.g. main-bot and provider-bot DMs) for `SearchChatMessages` on `#oxm_*` before history crawl.
  List<int> locatorTagTelegramSearchChatIds = const [],
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
    locatorTagTelegramSearchChatIds: locatorTagTelegramSearchChatIds,
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
  List<int> locatorTagTelegramSearchChatIds = const [],
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
      locatorTagTelegramSearchChatIds: locatorTagTelegramSearchChatIds,
      onDiagnostic: onDiagnostic,
    );
    if (byMessage != null) {
      if (byMessage.resolutionReason == 'recent_history_file_unique_id' ||
          byMessage.resolutionReason == 'history_scan_locator_tag_direct' ||
          byMessage.resolutionReason == 'history_scan_locator_tag_reply' ||
          byMessage.resolutionReason == 'global_search_locator_tag_direct' ||
          byMessage.resolutionReason == 'global_search_locator_tag_reply' ||
          byMessage.resolutionReason == 'bot_reply_search_tag' ||
          byMessage.resolutionReason == 'bot_reply_search_tag_direct_message') {
        onDiagnostic?.call(
          'Stored locator direct lookup did not resolve exact message for mediaFileId=$mediaFileId. Locator fallback recovered resolvedChatId=${byMessage.resolvedChatId} resolvedMessageId=${byMessage.locatorMessageId} requestedChatId=$locatorChatId requestedMessageId=$locatorMessageId reason=${byMessage.resolutionReason} fileId=${byMessage.file.id}',
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
  List<int> locatorTagTelegramSearchChatIds = const [],
  void Function(String message)? onDiagnostic,
}) async {
  final requestedMessageId = messageId;
  final chatCandidates = _candidateTelegramChatIds(chatId, exactOnly: exactChatIdOnly).toList(growable: false);

  for (final chatCandidate in chatCandidates) {
    await _openChatBestEffort(tdlib, chatCandidate, onDiagnostic);
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
  }

  final trimmedFileUniqueId = fileUniqueId?.trim() ?? '';
  final trimmedMediaId = mediaFileId.trim();

  if (trimmedMediaId.isNotEmpty && locatorTagTelegramSearchChatIds.isNotEmpty) {
    final seenSearchChat = <int>{};
    for (final searchChatId in locatorTagTelegramSearchChatIds) {
      if (!seenSearchChat.add(searchChatId)) continue;
      await _openChatBestEffort(tdlib, searchChatId, onDiagnostic);
      onDiagnostic?.call(
        'Trying Telegram SearchChatMessages for locator tag (env bot chat) chatId=$searchChatId mediaFileId=$trimmedMediaId',
      );
      final tagMatch = await _findMessageBySearchTagReply(
        tdlib: tdlib,
        mediaFileId: mediaFileId,
        chatId: searchChatId,
        fileUniqueId: fileUniqueId,
        onDiagnostic: onDiagnostic,
      );
      if (tagMatch != null) {
        return tagMatch;
      }
    }
  }

  if (trimmedMediaId.isNotEmpty) {
    final globalMatch = await _findLocatorTagViaGlobalSearchMessagesMedia(
      tdlib: tdlib,
      mediaFileId: trimmedMediaId,
      fileUniqueId: fileUniqueId,
      onDiagnostic: onDiagnostic,
    );
    if (globalMatch != null) {
      return globalMatch;
    }
  }

  if (trimmedFileUniqueId.isEmpty && trimmedMediaId.isEmpty) {
    return null;
  }

  for (final chatCandidate in chatCandidates) {
    await _openChatBestEffort(tdlib, chatCandidate, onDiagnostic);
    onDiagnostic?.call(
      'Trying Telegram GetChatHistory locator fallback for chatCandidate=$chatCandidate fileUniqueId=${trimmedFileUniqueId.isEmpty ? '(none)' : trimmedFileUniqueId} mediaId=${trimmedMediaId.isEmpty ? '(none)' : trimmedMediaId}',
    );
    final historyMatch = await _paginatedHistoryLocatorScanMediaResolver(
      tdlib: tdlib,
      chatId: chatCandidate,
      fileUniqueId: trimmedFileUniqueId.isEmpty ? null : trimmedFileUniqueId,
      mediaFileId: trimmedMediaId.isEmpty ? null : trimmedMediaId,
      onDiagnostic: onDiagnostic,
    );
    if (historyMatch != null) {
      return historyMatch;
    }
  }

  return null;
}

Future<_ExtractedFromMessage?> _findLocatorTagViaGlobalSearchMessagesMedia({
  required TdlibFacade tdlib,
  required String mediaFileId,
  String? fileUniqueId,
  void Function(String message)? onDiagnostic,
}) async {
  final trimmed = mediaFileId.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final queries = <String>{
    '$_kMediaLocatorSearchTagPrefix$trimmed',
    'oxm_$trimmed',
  }.toList(growable: false);
  final trimmedFu = fileUniqueId?.trim() ?? '';

  for (final query in queries) {
    try {
      onDiagnostic?.call('Trying Telegram SearchMessages (all non-secret chats) query=$query');
      final raw = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.SearchMessages(
          chatList: null,
          query: query,
          offset: '',
          limit: 50,
          filter: null,
          minDate: 0,
          maxDate: 0,
        ),
      );
      if (raw is! td.FoundMessages) {
        onDiagnostic?.call('SearchMessages unexpected type=${raw.runtimeType} query=$query');
        continue;
      }
      onDiagnostic?.call(
        'SearchMessages query=$query totalCount=${raw.totalCount} returned=${raw.messages.length}',
      );
      for (final msg in raw.messages) {
        final plain = _messagePlainTextForLocatorScanMedia(msg);
        if (plain == null || !_plainTextContainsLocatorTagMedia(plain, trimmed)) {
          continue;
        }
        final extracted = await _extractFromLocatorTaggedMessageMedia(
          tdlib: tdlib,
          tagMessage: msg,
          defaultChatId: msg.chatId,
          fileUniqueId: trimmedFu.isEmpty ? null : trimmedFu,
          logContext: 'global_search',
          onDiagnostic: onDiagnostic,
        );
        if (extracted != null) {
          return extracted;
        }
      }
    } on td.TdError catch (error) {
      onDiagnostic?.call(
        'SearchMessages failed query=$query: code=${error.code} message=${error.message}',
      );
    } catch (error) {
      onDiagnostic?.call('SearchMessages crashed query=$query: $error');
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
  final queries = <String>{
    _buildMediaLocatorSearchTag(mediaFileId),
    'oxm_${mediaFileId.trim()}',
  }.toList(growable: false);

  for (final query in queries) {
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
          limit: 50,
          filter: null,
          messageThreadId: 0,
        ),
      );
      if (result is! td.Messages || result.messages.isEmpty) {
        onDiagnostic?.call(
          'SearchChatMessages returned no messages for chatCandidate=$chatId query=$query',
        );
        continue;
      }

      final trimmedFileUniqueId = fileUniqueId?.trim() ?? '';
      for (final tagMessage in result.messages) {
        final extracted = await _extractFromLocatorTaggedMessageMedia(
          tdlib: tdlib,
          tagMessage: tagMessage,
          defaultChatId: chatId,
          fileUniqueId: trimmedFileUniqueId.isEmpty ? null : trimmedFileUniqueId,
          logContext: 'search_api',
          onDiagnostic: onDiagnostic,
        );
        if (extracted != null) {
          return extracted;
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
  }

  return null;
}


Future<td.TdObject> _sendWithTimeout({
  required TdlibFacade tdlib,
  required td.TdFunction request,
}) {
  return tdlib.send(request).timeout(_kResolveSendTimeout);
}

Future<void> _openChatBestEffort(
  TdlibFacade tdlib,
  int chatId,
  void Function(String message)? onDiagnostic,
) async {
  try {
    await _sendWithTimeout(tdlib: tdlib, request: td.OpenChat(chatId: chatId));
  } on td.TdError catch (error) {
    onDiagnostic?.call(
      'OpenChat best-effort failed for chatId=$chatId: code=${error.code} message=${error.message}',
    );
  } catch (error) {
    onDiagnostic?.call('OpenChat best-effort crashed for chatId=$chatId: $error');
  }
}

String? _messagePlainTextForLocatorScanMedia(td.Message message) {
  final content = message.content;
  if (content is td.MessageText) {
    return content.text.text;
  }
  if (content is td.MessageVideo) {
    return content.caption.text;
  }
  if (content is td.MessageDocument) {
    return content.caption.text;
  }
  if (content is td.MessageAnimation) {
    return content.caption.text;
  }
  if (content is td.MessagePhoto) {
    return content.caption.text;
  }
  return null;
}

bool _plainTextContainsLocatorTagMedia(String plain, String mediaIdTrimmed) {
  if (mediaIdTrimmed.isEmpty) return false;
  if (plain.contains('#oxm_$mediaIdTrimmed')) return true;
  if (plain.contains('oxm_$mediaIdTrimmed')) return true;
  return false;
}

String _mediaLocatorTagDirectReason(String logContext) {
  switch (logContext) {
    case 'history_tag':
      return 'history_scan_locator_tag_direct';
    case 'global_search':
      return 'global_search_locator_tag_direct';
    default:
      return 'bot_reply_search_tag_direct_message';
  }
}

String _mediaLocatorTagReplyReason(String logContext) {
  switch (logContext) {
    case 'history_tag':
      return 'history_scan_locator_tag_reply';
    case 'global_search':
      return 'global_search_locator_tag_reply';
    default:
      return 'bot_reply_search_tag';
  }
}

Future<_ExtractedFromMessage?> _extractFromLocatorTaggedMessageMedia({
  required TdlibFacade tdlib,
  required td.Message tagMessage,
  required int defaultChatId,
  required String? fileUniqueId,
  required String logContext,
  void Function(String message)? onDiagnostic,
}) async {
  final trimmedFileUniqueId = fileUniqueId?.trim() ?? '';

  final tagMessageFile = _extractFileFromMessage(tagMessage);
  if (tagMessageFile != null) {
    if (trimmedFileUniqueId.isNotEmpty && _messageFileUniqueId(tagMessage) != trimmedFileUniqueId) {
      onDiagnostic?.call(
        'Locator tag ($logContext) skipped tagMessageId=${tagMessage.id} because direct fileUniqueId did not match',
      );
    } else {
      onDiagnostic?.call(
        'Locator tag ($logContext) matched direct tagMessageId=${tagMessage.id} resolvedChatId=$defaultChatId resolvedMessageId=${tagMessage.id} fileId=${tagMessageFile.id}',
      );
      return _ExtractedFromMessage(
        file: tagMessageFile,
        locatorMessageId: tagMessage.id,
        resolutionReason: _mediaLocatorTagDirectReason(logContext),
        resolvedChatId: defaultChatId,
      );
    }
  }

  final replyTo = tagMessage.replyTo;
  if (replyTo is! td.MessageReplyToMessage) {
    return null;
  }
  onDiagnostic?.call(
    'Locator tag ($logContext) inspecting tagMessageId=${tagMessage.id} replyChatId=${replyTo.chatId} replyMessageId=${replyTo.messageId}',
  );
  try {
    final replied = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.GetMessage(
        chatId: replyTo.chatId,
        messageId: replyTo.messageId,
      ),
    );
    if (replied is! td.Message) return null;
    if (trimmedFileUniqueId.isNotEmpty && _messageFileUniqueId(replied) != trimmedFileUniqueId) {
      onDiagnostic?.call(
        'Locator tag ($logContext) skipped replyMessageId=${replyTo.messageId} because fileUniqueId did not match',
      );
      return null;
    }
    final file = _extractFileFromMessage(replied);
    if (file == null) return null;
    onDiagnostic?.call(
      'Locator tag ($logContext) matched tagMessageId=${tagMessage.id} resolvedChatId=${replyTo.chatId} resolvedMessageId=${replied.id} fileId=${file.id}',
    );
    return _ExtractedFromMessage(
      file: file,
      locatorMessageId: replied.id,
      resolutionReason: _mediaLocatorTagReplyReason(logContext),
      resolvedChatId: replyTo.chatId,
    );
  } on td.TdError catch (error) {
    onDiagnostic?.call(
      'Locator tag ($logContext) GetMessage failed replyChatId=${replyTo.chatId} replyMessageId=${replyTo.messageId}: code=${error.code} message=${error.message}',
    );
  } catch (error) {
    onDiagnostic?.call(
      'Locator tag ($logContext) GetMessage crashed replyChatId=${replyTo.chatId} replyMessageId=${replyTo.messageId}: $error',
    );
  }

  return null;
}

Future<_ExtractedFromMessage?> _paginatedHistoryLocatorScanMediaResolver({
  required TdlibFacade tdlib,
  required int chatId,
  required String? fileUniqueId,
  required String? mediaFileId,
  void Function(String message)? onDiagnostic,
}) async {
  final trimmedUnique = fileUniqueId?.trim() ?? '';
  final trimmedMedia = mediaFileId?.trim() ?? '';
  if (trimmedUnique.isEmpty && trimmedMedia.isEmpty) {
    return null;
  }

  const pageLimit = 100;
  const maxPages = 30;
  var fromMessageId = 0;
  var offset = 0;
  var scannedPages = 0;

  await _openChatBestEffort(tdlib, chatId, onDiagnostic);

  try {
    for (var page = 0; page < maxPages; page++) {
      final history = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.GetChatHistory(
          chatId: chatId,
          fromMessageId: fromMessageId,
          offset: offset,
          limit: pageLimit,
          onlyLocal: false,
        ),
      );
      if (history is! td.Messages || history.messages.isEmpty) {
        if (page == 0) {
          onDiagnostic?.call(
            'Telegram history locator scan found no messages for chatCandidate=$chatId',
          );
          return null;
        }
        break;
      }
      scannedPages++;
      final batch = history.messages;
      final playable = batch.where((m) => _extractFileFromMessage(m) != null).length;
      var withAnyUnique = 0;
      final samples = <String>[];
      for (final m in batch) {
        final u = _messageFileUniqueId(m);
        if (u != null && u.isNotEmpty) {
          withAnyUnique++;
          if (samples.length < 4) {
            samples.add(u.length > 10 ? '${u.substring(0, 10)}…' : u);
          }
        }
      }
      onDiagnostic?.call(
        'GetChatHistory chatId=$chatId page=$page batchSize=${batch.length} '
        'msgIdRange=${batch.isEmpty ? 'empty' : '${batch.last.id}..${batch.first.id}'} '
        'playableAttachments=$playable messagesWithFileUniqueId=$withAnyUnique fileUniqueSamples=$samples',
      );

      for (final message in batch) {
        if (trimmedUnique.isNotEmpty) {
          if (_messageFileUniqueId(message) == trimmedUnique) {
            final file = _extractFileFromMessage(message);
            if (file != null) {
              onDiagnostic?.call(
                'Telegram history locator scan matched fileUniqueId chatCandidate=$chatId resolvedMessageId=${message.id} fileId=${file.id}',
              );
              return _ExtractedFromMessage(
                file: file,
                locatorMessageId: message.id,
                resolutionReason: 'recent_history_file_unique_id',
                resolvedChatId: chatId,
              );
            }
          }
        }
        if (trimmedMedia.isNotEmpty) {
          final plain = _messagePlainTextForLocatorScanMedia(message);
          if (plain != null && _plainTextContainsLocatorTagMedia(plain, trimmedMedia)) {
            onDiagnostic?.call(
              'Telegram history locator scan found #oxm tag in plain text messageId=${message.id} chatCandidate=$chatId',
            );
            final viaTag = await _extractFromLocatorTaggedMessageMedia(
              tdlib: tdlib,
              tagMessage: message,
              defaultChatId: chatId,
              fileUniqueId: trimmedUnique.isEmpty ? null : trimmedUnique,
              logContext: 'history_tag',
              onDiagnostic: onDiagnostic,
            );
            if (viaTag != null) {
              return viaTag;
            }
          }
        }
      }

      if (batch.length < pageLimit) {
        onDiagnostic?.call(
          'GetChatHistory chatId=$chatId stopping: batchSize=${batch.length} < pageLimit=$pageLimit',
        );
        break;
      }

      final oldestInBatch = batch.last.id;
      fromMessageId = oldestInBatch;
      offset = -pageLimit;
    }

    onDiagnostic?.call(
      scannedPages == 0
          ? 'Telegram history locator scan found no fileUniqueId or locator tag for chatCandidate=$chatId'
          : 'Telegram history locator scan found no fileUniqueId or locator tag for chatCandidate=$chatId after $scannedPages page(s) (up to ${scannedPages * pageLimit} messages)',
    );
  } on td.TdError catch (error) {
    onDiagnostic?.call(
      'Telegram history locator scan failed for chatCandidate=$chatId: code=${error.code} message=${error.message}',
    );
  } catch (error) {
    onDiagnostic?.call(
      'Telegram history locator scan crashed for chatCandidate=$chatId: $error',
    );
  }

  return null;
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
