import 'dart:async';

import 'package:tdlib/td_api.dart' as td;

import '../../core/debug/app_debug_log.dart';
import 'tdlib_facade.dart';

void _locatorLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.locator);

const Duration _kResolveSendTimeout = Duration(seconds: 8);
const Duration _kResolveOverallTimeout = Duration(seconds: 35);

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

/// Global resolver for `mediaFileId -> td.File` used by stream/download flows.
///
/// Strategy:
/// 1) Try direct message locator from API.
/// 2) Try remote-id locator from API.
/// 3) Fail fast; recovery is handled by upper layers (API/provider flow).
Future<ResolvedTelegramMediaFile?> resolveTelegramMediaFile({
  required TdlibFacade tdlib,
  required String mediaFileId,
  String? telegramFileId,
  String? locatorType,
  int? locatorChatId,
  int? locatorMessageId,
  String? locatorBotUsername,
  String? locatorRemoteFileId,
  String? expectedFileUniqueId,
}) async {
  return _resolveTelegramMediaFileImpl(
    tdlib: tdlib,
    mediaFileId: mediaFileId,
    telegramFileId: telegramFileId,
    locatorType: locatorType,
    locatorChatId: locatorChatId,
    locatorMessageId: locatorMessageId,
    locatorBotUsername: locatorBotUsername,
    locatorRemoteFileId: locatorRemoteFileId,
    expectedFileUniqueId: expectedFileUniqueId,
  ).timeout(_kResolveOverallTimeout, onTimeout: () {
    _locatorLog(
      'Locator: resolve timeout after ${_kResolveOverallTimeout.inSeconds}s '
      'mediaFileId=$mediaFileId',
    );
    return null;
  });
}

Future<ResolvedTelegramMediaFile?> _resolveTelegramMediaFileImpl({
  required TdlibFacade tdlib,
  required String mediaFileId,
  String? telegramFileId,
  String? locatorType,
  int? locatorChatId,
  int? locatorMessageId,
  String? locatorBotUsername,
  String? locatorRemoteFileId,
  String? expectedFileUniqueId,
}) async {
  _locatorLog(
    'Locator: resolve start mediaFileId=$mediaFileId '
    'locatorType=$locatorType chat=$locatorChatId msg=$locatorMessageId '
    'locatorRemote=${_shortId(locatorRemoteFileId)} telegramFile=${_shortId(telegramFileId)} '
    'expectedUnique=${_shortId(expectedFileUniqueId)}',
  );
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
      );
      if (byRuntimeMessage != null) {
        _logResolved(
          reason: 'direct_runtime_message',
          chatId: runtimeChatId,
          messageId: byRuntimeMessage.locatorMessageId,
          file: byRuntimeMessage.file,
        );
        return ResolvedTelegramMediaFile(
          file: byRuntimeMessage.file,
          locatorChatId: runtimeChatId,
          locatorMessageId: byRuntimeMessage.locatorMessageId,
          locatorType: 'CHAT_MESSAGE',
          resolutionReason: 'direct_runtime_message',
        );
      }
      final byRuntimeUnique = await _resolveByHistoryUniqueId(
        tdlib: tdlib,
        chatId: runtimeChatId,
        expectedFileUniqueId: expectedFileUniqueId,
      );
      if (byRuntimeUnique != null) {
        _logResolved(
          reason: 'history_unique_id_match',
          chatId: byRuntimeUnique.locatorChatId,
          messageId: byRuntimeUnique.locatorMessageId,
          file: byRuntimeUnique.file,
        );
        return byRuntimeUnique;
      }
    }
  }

  if (locatorType == 'CHAT_MESSAGE' &&
      locatorChatId != null &&
      locatorMessageId != null) {
    final byMsg = await _resolveFileByMessage(
      tdlib: tdlib,
      chatId: locatorChatId,
      messageId: locatorMessageId,
    );
    if (byMsg != null) {
      _logResolved(
        reason: 'direct_chat_message',
        chatId: locatorChatId,
        messageId: byMsg.locatorMessageId,
        file: byMsg.file,
      );
      return ResolvedTelegramMediaFile(
        file: byMsg.file,
        locatorChatId: locatorChatId,
        locatorMessageId: byMsg.locatorMessageId,
        locatorType: 'CHAT_MESSAGE',
        resolutionReason: 'direct_chat_message',
      );
    }
    final byUnique = await _resolveByHistoryUniqueId(
      tdlib: tdlib,
      chatId: locatorChatId,
      expectedFileUniqueId: expectedFileUniqueId,
    );
    if (byUnique != null) {
      _logResolved(
        reason: 'history_unique_id_match',
        chatId: byUnique.locatorChatId,
        messageId: byUnique.locatorMessageId,
        file: byUnique.file,
      );
      return byUnique;
    }
  }

  if ((locatorRemoteFileId ?? '').trim().isNotEmpty) {
    try {
      final remoteFile = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.GetRemoteFile(
          remoteFileId: locatorRemoteFileId!.trim(),
          fileType: null,
        ),
        op: 'GetRemoteFile(locatorRemoteFileId)',
      );
      if (remoteFile is td.File) {
        _logResolved(
          reason: 'get_remote_file_locator_remote',
          chatId: null,
          messageId: null,
          file: remoteFile,
        );
        return ResolvedTelegramMediaFile(
          file: remoteFile,
          locatorType: 'REMOTE_FILE_ID',
          resolutionReason: 'get_remote_file_locator_remote',
        );
      }
    } catch (_) {}
  }

  if ((telegramFileId ?? '').trim().isNotEmpty) {
    try {
      final remoteFile = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.GetRemoteFile(
          remoteFileId: telegramFileId!.trim(),
          fileType: null,
        ),
        op: 'GetRemoteFile(telegramFileId)',
      );
      if (remoteFile is td.File) {
        _logResolved(
          reason: 'get_remote_file_telegram_file',
          chatId: null,
          messageId: null,
          file: remoteFile,
        );
        return ResolvedTelegramMediaFile(
          file: remoteFile,
          locatorType: 'REMOTE_FILE_ID',
          resolutionReason: 'get_remote_file_telegram_file',
        );
      }
    } catch (e) {
      _locatorLog('Locator: GetRemoteFile(telegramFileId) failed: $e');
    }
  }

  _locatorLog('Locator: resolve failed mediaFileId=$mediaFileId');
  return null;
}

Future<ResolvedTelegramMediaFile?> _resolveByHistoryUniqueId({
  required TdlibFacade tdlib,
  required int chatId,
  required String? expectedFileUniqueId,
}) async {
  final unique = (expectedFileUniqueId ?? '').trim();
  if (unique.isEmpty) return null;
  _locatorLog(
    'Locator: history unique fallback start chat=$chatId unique=${_shortId(unique)}',
  );
  try {
    var fromMessageId = 0;
    const pageSize = 40;
    const maxPages = 6;
    for (var page = 0; page < maxPages; page++) {
      final histObj = await _sendWithTimeout(
        tdlib: tdlib,
        request: td.GetChatHistory(
          chatId: chatId,
          fromMessageId: fromMessageId,
          offset: 0,
          limit: pageSize,
          onlyLocal: false,
        ),
        op: 'GetChatHistory(unique chat=$chatId page=$page)',
      );
      if (histObj is! td.Messages) return null;
      final messages = histObj.messages;
      _locatorLog(
        'Locator: history unique fetched chat=$chatId page=$page count=${messages.length}',
      );
      if (messages.isEmpty) return null;
      for (final msg in messages) {
        final direct = _extractFileFromMessage(msg);
        if (direct == null) continue;
        final uid = _fileUniqueIdOf(direct);
        if (uid == null) continue;
        if (uid != unique) continue;
        return ResolvedTelegramMediaFile(
          file: direct,
          locatorChatId: chatId,
          locatorMessageId: msg.id,
          locatorType: 'CHAT_MESSAGE',
          resolutionReason: 'history_unique_id_match',
        );
      }
      final last = messages.last.id;
      if (last == fromMessageId) return null;
      fromMessageId = last;
    }
  } catch (_) {}
  return null;
}

Future<_ExtractedFromMessage?> _resolveFileByMessage({
  required TdlibFacade tdlib,
  required int chatId,
  required int messageId,
}) async {
  try {
    final msgObj = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.GetMessage(chatId: chatId, messageId: messageId),
      op: 'GetMessage(chat=$chatId msg=$messageId)',
    );
    if (msgObj is! td.Message) return null;
    final direct = _extractFileFromMessage(msgObj);
    if (direct != null) {
      return _ExtractedFromMessage(file: direct, locatorMessageId: messageId);
    }
    return null;
  } on td.TdError catch (e) {
    _locatorLog(
      'Locator: GetMessage failed chat=$chatId msg=$messageId '
      'code=${e.code} message=${e.message}',
    );
    return null;
  } catch (e) {
    _locatorLog(
        'Locator: GetMessage failed chat=$chatId msg=$messageId err=$e');
    return null;
  }
}

Future<int?> _resolveBotPrivateChatId(
    TdlibFacade tdlib, String botUsername) async {
  try {
    final resolved = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.SearchPublicChat(username: botUsername),
      op: 'SearchPublicChat($botUsername)',
    );
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      return null;
    }
    final botUserId = (resolved.type as td.ChatTypePrivate).userId;
    final privateChat = await _sendWithTimeout(
      tdlib: tdlib,
      request: td.CreatePrivateChat(userId: botUserId, force: false),
      op: 'CreatePrivateChat(user=$botUserId)',
    );
    if (privateChat is td.Chat) return privateChat.id;
  } catch (_) {}
  return null;
}

Future<td.TdObject> _sendWithTimeout({
  required TdlibFacade tdlib,
  required td.TdFunction request,
  required String op,
}) async {
  try {
    return await tdlib.send(request).timeout(_kResolveSendTimeout);
  } on TimeoutException {
    _locatorLog(
      'Locator: timeout op=$op after ${_kResolveSendTimeout.inSeconds}s',
    );
    rethrow;
  }
}

td.File? _extractFileFromMessage(td.Message msg) {
  final content = msg.content;
  if (content is td.MessageVideo) return content.video.video;
  if (content is td.MessageDocument) return content.document.document;
  if (content is td.MessageAnimation) return content.animation.animation;
  if (content is td.MessageVideoNote) return content.videoNote.video;
  return null;
}

String? _remoteFileIdOf(td.File file) {
  try {
    final dynamic remote = (file as dynamic).remote;
    final dynamic id = remote?.id;
    if (id is String) {
      final t = id.trim();
      if (t.isNotEmpty) return t;
    }
  } catch (_) {}
  return null;
}

String? _fileUniqueIdOf(td.File file) {
  try {
    final dynamic remote = (file as dynamic).remote;
    final dynamic uid = remote?.uniqueId;
    if (uid is String) {
      final t = uid.trim();
      if (t.isNotEmpty) return t;
    }
  } catch (_) {}
  return null;
}

void _logResolved({
  required String reason,
  required int? chatId,
  required int? messageId,
  required td.File file,
}) {
  _locatorLog(
    'Locator: resolved reason=$reason chat=$chatId msg=$messageId '
    'fileId=${file.id} remote=${_shortId(_remoteFileIdOf(file))}',
  );
}

String _shortId(String? id) {
  final t = (id ?? '').trim();
  if (t.isEmpty) return '-';
  if (t.length <= 16) return t;
  return '${t.substring(0, 6)}...${t.substring(t.length - 6)}';
}

