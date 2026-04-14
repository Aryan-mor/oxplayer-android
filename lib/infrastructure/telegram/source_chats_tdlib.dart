import 'package:tdlib/td_api.dart' as td;

import '../../utils/app_logger.dart';
import 'tdlib_facade.dart';

/// [td.TdError] does not override [Object.toString]; use this for UI and logs.
String describeTdlibError(Object error) {
  if (error is td.TdError) {
    return 'TDLib ${error.code}: ${error.message}';
  }
  return error.toString();
}

/// Picker bucket aligned with API `GET /me/chats` `bucket` query.
enum SourceChatPickerBucket { chats, groups, supergroups, channels, bots }

/// Lightweight row for the TDLib-backed My Telegram config list.
class TdlibPickerChatRow {
  const TdlibPickerChatRow({
    required this.chatId,
    required this.title,
    required this.apiChatType,
    required this.peerIsBot,
    required this.isSavedMessages,
    this.isForum = false,
    this.localAvatarPath,
  });

  final int chatId;
  final String title;

  /// Prisma/API enum string: private, group, supergroup, channel, saved_messages
  final String apiChatType;
  final bool peerIsBot;
  final bool isSavedMessages;
  /// `GetSupergroup.is_forum` when [apiChatType] is `supergroup`.
  final bool isForum;
  final String? localAvatarPath;

  bool matchesBucket(SourceChatPickerBucket b) {
    switch (b) {
      case SourceChatPickerBucket.chats:
        return isSavedMessages || (apiChatType == 'private' && !peerIsBot);
      case SourceChatPickerBucket.groups:
        return apiChatType == 'group' || (apiChatType == 'supergroup' && !isForum);
      case SourceChatPickerBucket.supergroups:
        return apiChatType == 'supergroup' && isForum;
      case SourceChatPickerBucket.channels:
        return apiChatType == 'channel';
      case SourceChatPickerBucket.bots:
        return apiChatType == 'private' && peerIsBot;
    }
  }
}

Future<int> tdlibGetSelfUserId(TdlibFacade facade) async {
  final me = await facade.send(const td.GetMe()) as td.User;
  return me.id;
}

Future<void> tdlibLoadChatsPage(TdlibFacade facade, {int limit = 40}) async {
  try {
    await facade.send(td.LoadChats(chatList: const td.ChatListMain(), limit: limit));
  } catch (_) {
    // 404 = nothing more to load
  }
}

Future<List<int>> tdlibGetMainChatIds(TdlibFacade facade, int limit) async {
  final res = await facade.send(td.GetChats(chatList: const td.ChatListMain(), limit: limit));
  if (res is! td.Chats) return const [];
  return List<int>.from(res.chatIds);
}

Future<td.User?> tdlibGetUser(TdlibFacade facade, int userId) async {
  final o = await facade.send(td.GetUser(userId: userId));
  return o is td.User ? o : null;
}

Future<TdlibPickerChatRow?> tdlibBuildPickerRow({
  required TdlibFacade facade,
  required td.Chat chat,
  required int selfUserId,
  String savedMessagesTitle = 'Saved Messages',
  String? localAvatarPath,
}) async {
  final t = chat.type;
  if (t is td.ChatTypePrivate) {
    final u = await tdlibGetUser(facade, t.userId);
    final isSelf = t.userId == selfUserId;
    final isBot = u?.type is td.UserTypeBot;
    final apiType = isSelf ? 'saved_messages' : 'private';
    return TdlibPickerChatRow(
      chatId: chat.id,
      title: isSelf ? savedMessagesTitle : (chat.title.trim().isEmpty ? 'User' : chat.title.trim()),
      apiChatType: apiType,
      peerIsBot: isBot,
      isSavedMessages: isSelf,
      localAvatarPath: localAvatarPath,
    );
  }
  if (t is td.ChatTypeBasicGroup) {
    return TdlibPickerChatRow(
      chatId: chat.id,
      title: chat.title.trim().isEmpty ? 'Group' : chat.title.trim(),
      apiChatType: 'group',
      peerIsBot: false,
      isSavedMessages: false,
      localAvatarPath: localAvatarPath,
    );
  }
  if (t is td.ChatTypeSupergroup) {
    var isForum = false;
    if (!t.isChannel) {
      try {
        final sg = await facade.send(td.GetSupergroup(supergroupId: t.supergroupId));
        if (sg is td.Supergroup) isForum = sg.isForum;
      } catch (_) {}
    }
    return TdlibPickerChatRow(
      chatId: chat.id,
      title: chat.title.trim().isEmpty ? (t.isChannel ? 'Channel' : 'Group') : chat.title.trim(),
      apiChatType: t.isChannel ? 'channel' : 'supergroup',
      peerIsBot: false,
      isSavedMessages: false,
      isForum: isForum,
      localAvatarPath: localAvatarPath,
    );
  }
  return null;
}

Future<td.Chat?> tdlibGetChat(TdlibFacade facade, int chatId) async {
  final o = await facade.send(td.GetChat(chatId: chatId));
  return o is td.Chat ? o : null;
}

/// Loads all [td.ForumTopic] rows for a forum supergroup (paginated [GetForumTopics]).
Future<List<td.ForumTopic>> tdlibLoadAllForumTopics(TdlibFacade facade, int chatId) async {
  try {
    await facade.send(td.OpenChat(chatId: chatId));
  } catch (_) {
    // Best-effort; [GetForumTopics] may still succeed.
  }

  final out = <td.ForumTopic>[];
  var offsetDate = 0;
  var offsetMessageId = 0;
  var offsetThreadId = 0;
  while (true) {
    td.TdObject raw;
    try {
      raw = await facade.send(
        td.GetForumTopics(
          chatId: chatId,
          query: '',
          offsetDate: offsetDate,
          offsetMessageId: offsetMessageId,
          offsetMessageThreadId: offsetThreadId,
          limit: 100,
        ),
      );
    } on td.TdError catch (e) {
      final desc = describeTdlibError(e);
      appLogger.e('GetForumTopics failed chatId=$chatId', error: desc, stackTrace: StackTrace.current);
      final msg = e.message.toLowerCase();
      // Indexed/API said "forum" but TDLib says this peer is not forum-capable — degrade to "All videos" only.
      if (msg.contains('not a forum') || msg.contains('is not a forum') || msg.contains('not supported')) {
        appLogger.w('GetForumTopics: treating as non-forum chatId=$chatId — $desc');
        return const <td.ForumTopic>[];
      }
      throw Exception(desc);
    }
    if (raw is! td.ForumTopics) break;
    out.addAll(raw.topics);
    if (raw.topics.isEmpty) break;
    offsetDate = raw.nextOffsetDate;
    offsetMessageId = raw.nextOffsetMessageId;
    offsetThreadId = raw.nextOffsetMessageThreadId;
    if (offsetDate == 0 && offsetMessageId == 0 && offsetThreadId == 0) break;
  }
  out.sort((a, b) {
    if (a.info.isGeneral != b.info.isGeneral) return a.info.isGeneral ? -1 : 1;
    if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
    return a.info.name.toLowerCase().compareTo(b.info.name.toLowerCase());
  });
  return out;
}
