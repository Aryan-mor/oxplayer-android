import 'package:tdlib/td_api.dart' as td;

import '../core/config/app_config.dart';
import '../core/debug/app_debug_log.dart';
import '../infrastructure/telegram/tdlib_facade.dart';

void _memLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.membership);

/// Pre–TDLib-1.8 JSON API (still used by some `libtdjson.so` builds in the wild).
final class _UnblockUserLegacy extends td.TdFunction {
  const _UnblockUserLegacy({required this.userId});
  final int userId;

  @override
  Map<String, dynamic> toJson([dynamic extra]) => {
        '@type': 'unblockUser',
        'user_id': userId,
        if (extra != null) '@extra': extra,
      };

  @override
  String getConstructor() => 'unblockUser';
}

/// [toggleMessageSenderIsBlocked] is missing in older libtdjson → fall back to [unblockUser].
Future<bool> _unblockBotUserCompat(
  TdlibFacade facade,
  int userId,
  String ctx,
) async {
  try {
    await facade.send(
      td.ToggleMessageSenderIsBlocked(
        senderId: td.MessageSenderUser(userId: userId),
        isBlocked: false,
      ),
    );
    _memLog('$ctx: unblock via toggleMessageSenderIsBlocked ok');
    return true;
  } on td.TdError catch (e) {
    final msg = e.message;
    final noToggle = e.code == 400 &&
        msg.contains('toggleMessageSenderIsBlocked') &&
        (msg.contains('Unknown class') || msg.contains('unknown class'));
    if (!noToggle) {
      _memLog('$ctx: unblock error ${e.message} (${e.code})');
      return false;
    }
    _memLog('$ctx: toggle unknown to libtdjson — trying unblockUser');
    try {
      await facade.send(_UnblockUserLegacy(userId: userId));
      _memLog('$ctx: unblockUser ok');
      return true;
    } on td.TdError catch (e2) {
      _memLog('$ctx: unblockUser failed ${e2.message} (${e2.code})');
      return false;
    }
  }
}

bool _isMember(td.ChatMemberStatus status) {
  return status is td.ChatMemberStatusCreator ||
      status is td.ChatMemberStatusAdministrator ||
      status is td.ChatMemberStatusMember ||
      status is td.ChatMemberStatusRestricted;
}

bool _isMemberListInaccessible(td.TdError e) {
  final m = e.message.toLowerCase();
  return m.contains('inaccessible') && m.contains('member');
}

bool _isAlreadyInChat(td.TdError e) {
  final m = e.message.toUpperCase();
  return m.contains('USER_ALREADY_PARTICIPANT') ||
      m.contains('ALREADY_PARTICIPANT') ||
      m.contains('CHAT_ALREADY');
}

/// True if [msg] is our outgoing send that never succeeded (blocked bot, network, etc.).
bool _isOutgoingFailedMessage(td.Message msg) {
  if (!msg.isOutgoing) return false;
  return msg.sendingState is td.MessageSendingStateFailed;
}

/// Whether this chat already has a real bot thread (not only a dead failed outgoing).
bool _hasUsableBotLastMessage(td.Chat chat) {
  final lm = chat.lastMessage;
  if (lm == null) return false;
  return !_isOutgoingFailedMessage(lm);
}

Future<int> _resolveUserId(TdlibFacade facade, String username) async {
  final clean = username.replaceFirst('@', '').trim();
  if (clean.isEmpty) return 0;
  final chat = await facade.send(td.SearchPublicChat(username: clean));
  if (chat is! td.Chat) return 0;
  final t = chat.type;
  if (t is td.ChatTypePrivate) return t.userId;
  return 0;
}

Future<void> _ensureBotReady(
  TdlibFacade facade,
  String botUsername,
) async {
  _memLog('bot @$botUsername: resolve user…');
  final botUserId = await _resolveUserId(facade, botUsername);
  if (botUserId == 0) {
    _memLog('bot @$botUsername: SearchPublicChat did not yield private user id (check username)');
    return;
  }
  _memLog('bot @$botUsername: botUserId=$botUserId');

  final priv = await facade.send(
    td.CreatePrivateChat(userId: botUserId, force: false),
  );
  if (priv is! td.Chat) {
    _memLog('bot @$botUsername: CreatePrivateChat failed (not a Chat)');
    return;
  }
  _memLog('bot @$botUsername: private chatId=${priv.id}');

  final got = await facade.send(td.GetChat(chatId: priv.id));
  if (got is! td.Chat) {
    _memLog('bot @$botUsername: GetChat failed (not a Chat)');
    return;
  }
  var chat = got;
  var unblockedThisRun = false;
  _memLog(
    'bot @$botUsername: GetChat isBlocked=${chat.isBlocked} '
    'usableLastMsg=${_hasUsableBotLastMessage(chat)} '
    'lastMessageId=${chat.lastMessage?.id}',
  );
  if (chat.isBlocked) {
    _memLog('bot @$botUsername: chat flagged blocked — unblock…');
    final unblocked = await _unblockBotUserCompat(
      facade,
      botUserId,
      'bot @$botUsername (initial)',
    );
    if (unblocked) unblockedThisRun = true;
    final again = await facade.send(td.GetChat(chatId: priv.id));
    if (again is td.Chat) chat = again;
    _memLog('bot @$botUsername: after unblock GetChat isBlocked=${chat.isBlocked}');
  }
  if (chat.isBlocked) {
    _memLog('bot @$botUsername: still blocked — skip SendBotStartMessage');
    return;
  }

  final usable = _hasUsableBotLastMessage(chat);
  final needStart = unblockedThisRun || !usable;
  _memLog(
    'bot @$botUsername: needStart=$needStart (unblockedThisRun=$unblockedThisRun usable=$usable)',
  );
  if (!needStart) {
    _memLog('bot @$botUsername: skip SendBotStartMessage (already active)');
    return;
  }

  // Even when [Chat.isBlocked] is false, TDLib/Telegram can still treat the bot as blocked
  // (failed outgoing with YOU_BLOCKED_USER). Always clear block before [SendBotStartMessage].
  _memLog('bot @$botUsername: pre-start unblock (heal stale block)…');
  await _unblockBotUserCompat(
    facade,
    botUserId,
    'bot @$botUsername pre-start',
  );
  final afterPre = await facade.send(td.GetChat(chatId: priv.id));
  if (afterPre is td.Chat) {
    chat = afterPre;
    _memLog(
      'bot @$botUsername: after pre-start GetChat isBlocked=${chat.isBlocked}',
    );
  }

  _memLog('bot @$botUsername: SendBotStartMessage…');
  try {
    await facade.send(
      td.SendBotStartMessage(
        botUserId: botUserId,
        chatId: priv.id,
        parameter: '',
      ),
    );
    _memLog('bot @$botUsername: SendBotStartMessage ok');
  } on td.TdError catch (e) {
    _memLog(
      'bot @$botUsername: SendBotStartMessage TdError: ${e.message} (${e.code})',
    );
  }
}

Future<void> _ensureChannelJoined(
  TdlibFacade facade,
  int myUserId,
  String channelUsername,
) async {
  final clean = channelUsername.replaceFirst('@', '').trim();
  if (clean.isEmpty) return;

  _memLog('channel @$clean: SearchPublicChat…');
  final chat = await facade.send(td.SearchPublicChat(username: clean));
  if (chat is! td.Chat) {
    _memLog('channel @$clean: SearchPublicChat did not return Chat');
    return;
  }
  final chatId = chat.id;
  _memLog('channel @$clean: chatId=$chatId myUserId=$myUserId');

  td.ChatMember? member;
  try {
    final res = await facade.send(
      td.GetChatMember(
        chatId: chatId,
        memberId: td.MessageSenderUser(userId: myUserId),
      ),
    );
    member = res is td.ChatMember ? res : null;
    if (member != null) {
      _memLog('channel @$clean: GetChatMember status=${member.status.runtimeType}');
    }
  } on td.TdError catch (e) {
    if (!_isMemberListInaccessible(e)) rethrow;
    _memLog('channel @$clean: GetChatMember inaccessible (${e.message}) — will try JoinChat');
    member = null;
  }

  if (member != null && _isMember(member.status)) {
    _memLog('channel @$clean: already a member — skip JoinChat');
    return;
  }

  _memLog('channel @$clean: JoinChat…');
  try {
    await facade.send(td.JoinChat(chatId: chatId));
    _memLog('channel @$clean: JoinChat ok');
  } on td.TdError catch (e) {
    if (_isAlreadyInChat(e)) {
      _memLog('channel @$clean: JoinChat already participant');
      return;
    }
    _memLog('channel @$clean: JoinChat error ${e.message} (${e.code})');
    rethrow;
  }
}

/// Channel membership check via [GetChatMember], with a fallback when Telegram hides the member list.
Future<bool> _verifyChannelMembership(
  TdlibFacade tdlib,
  int myUserId,
  String channelUsername,
) async {
  final clean = channelUsername.replaceFirst('@', '').trim();
  if (clean.isEmpty) return true;
  final chat = await tdlib.send(td.SearchPublicChat(username: clean));
  if (chat is! td.Chat) return false;
  final chatId = chat.id;

  try {
    final res = await tdlib.send(
      td.GetChatMember(
        chatId: chatId,
        memberId: td.MessageSenderUser(userId: myUserId),
      ),
    );
    if (res is! td.ChatMember) return false;
    return _isMember(res.status);
  } on td.TdError catch (e) {
    if (!_isMemberListInaccessible(e)) rethrow;
    try {
      await tdlib.send(td.JoinChat(chatId: chatId));
      return true;
    } on td.TdError catch (e2) {
      return _isAlreadyInChat(e2);
    }
  }
}

/// Ensures the user has joined the mandatory channel and each mandatory bot:
/// channel → [JoinChat] if needed; bot → unblock if blocked, then [SendBotStartMessage] if needed.
Future<bool> ensureMembershipRequirements({
  required TdlibFacade tdlib,
  required AppConfig config,
}) async {
  await tdlib.ensureAuthorized();
  final me = await tdlib.send(const td.GetMe());
  if (me is! td.User) return false;
  final myId = me.id;

  final channel = config.requiredChannelUsername.trim();
  final mainBot = config.botUsername.trim();
  final providerBot = config.providerBotUsername.trim();

  _memLog(
    'ensureMembershipRequirements: myId=$myId channel="$channel" '
    'mainBot="$mainBot" secondBot="$providerBot"',
  );

  if (channel.isNotEmpty) {
    await _ensureChannelJoined(tdlib, myId, channel);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } else {
    _memLog('ensureMembershipRequirements: no REQUIRED_CHANNEL_USERNAME');
  }
  if (mainBot.isNotEmpty) {
    await _ensureBotReady(tdlib, mainBot);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } else {
    _memLog('ensureMembershipRequirements: no main BOT_USERNAME');
  }
  if (providerBot.isNotEmpty) {
    await _ensureBotReady(tdlib, providerBot);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } else {
    _memLog('ensureMembershipRequirements: no PROVIDER_BOT_USERNAME');
  }

  final verified = await verifyMembershipRequirements(tdlib: tdlib, config: config);
  _memLog('ensureMembershipRequirements: verify result=$verified');
  return verified;
}

/// Verifies membership after [ensureMembershipRequirements]. May call [JoinChat] on channels
/// only when [GetChatMember] fails with a hidden member list (TDLib limitation).
Future<bool> verifyMembershipRequirements({
  required TdlibFacade tdlib,
  required AppConfig config,
}) async {
  await tdlib.ensureAuthorized();
  final me = await tdlib.send(const td.GetMe());
  if (me is! td.User) return false;
  final myId = me.id;

  final channel = config.requiredChannelUsername.trim();
  final mainBot = config.botUsername.trim();
  final providerBot = config.providerBotUsername.trim();

  if (channel.isNotEmpty) {
    _memLog('verify: channel @$channel …');
    final ok = await _verifyChannelMembership(tdlib, myId, channel);
    _memLog('verify: channel member=$ok');
    if (!ok) return false;
  }

  Future<bool> botStarted(String username) async {
    if (username.isEmpty) return true;
    _memLog('verify bot @$username …');
    final uid = await _resolveUserId(tdlib, username);
    if (uid == 0) {
      _memLog('verify bot @$username: FAIL resolve user id');
      return false;
    }
    final priv = await tdlib.send(
      td.CreatePrivateChat(userId: uid, force: false),
    );
    if (priv is! td.Chat) {
      _memLog('verify bot @$username: FAIL CreatePrivateChat');
      return false;
    }

    final rawChat = await tdlib.send(td.GetChat(chatId: priv.id));
    if (rawChat is! td.Chat) {
      _memLog('verify bot @$username: FAIL GetChat');
      return false;
    }
    td.Chat chatObj = rawChat;
    if (chatObj.isBlocked) {
      _memLog('verify bot @$username: blocked in verify — try unblock');
      await _unblockBotUserCompat(
        tdlib,
        uid,
        'verify bot @$username',
      );
      final again = await tdlib.send(td.GetChat(chatId: priv.id));
      if (again is td.Chat) chatObj = again;
    }
    if (chatObj.isBlocked) {
      _memLog('verify bot @$username: FAIL still blocked');
      return false;
    }

    if (chatObj.type is td.ChatTypePrivate) {
      final usable = _hasUsableBotLastMessage(chatObj);
      final canSend = chatObj.permissions.canSendBasicMessages;
      final ok = usable || canSend;
      _memLog(
        'verify bot @$username: private usable=$usable canSendBasic=$canSend → $ok',
      );
      return ok;
    }

    try {
      final member = await tdlib.send(
        td.GetChatMember(
          chatId: priv.id,
          memberId: td.MessageSenderUser(userId: myId),
        ),
      );
      if (member is! td.ChatMember) {
        _memLog('verify bot @$username: FAIL GetChatMember not ChatMember');
        return false;
      }
      final ok = _isMember(member.status);
      _memLog('verify bot @$username: GetChatMember member=$ok');
      return ok;
    } on td.TdError catch (e) {
      if (_isMemberListInaccessible(e)) {
        _memLog('verify bot @$username: FAIL member list inaccessible');
        return false;
      }
      rethrow;
    }
  }

  if (!await botStarted(mainBot)) {
    _memLog('verify: FAIL main bot');
    return false;
  }
  if (providerBot.isNotEmpty && !await botStarted(providerBot)) {
    _memLog('verify: FAIL second bot');
    return false;
  }

  _memLog('verify: all checks OK');
  return true;
}

