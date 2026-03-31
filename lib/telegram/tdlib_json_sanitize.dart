import 'dart:convert';

/// TDLib JSON from newer [libtdjson] may omit fields or use newer shapes than
/// `package:tdlib` 1.6.x expects. Patch maps before [convertToObject].
String sanitizeTdlibJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      _walk(decoded);
    }
    return jsonEncode(decoded);
  } catch (_) {
    // Malformed JSON — return as-is; convertToObject will fail similarly.
  }
  return raw;
}

void _walk(dynamic node) {
  if (node is Map<String, dynamic>) {
    final t = node['@type'];
    if (t == 'chatFolderInfo') {
      _patchChatFolderInfo(node);
    } else if (t == 'chatPermissions') {
      _patchChatPermissions(node);
    } else if (t == 'supergroup') {
      _patchSupergroup(node);
    } else if (t == 'chatTypeSupergroup') {
      _patchChatTypeSupergroup(node);
    } else if (t == 'chatNotificationSettings') {
      _patchChatNotificationSettings(node);
    } else if (t == 'messageInteractionInfo') {
      _patchMessageInteractionInfo(node);
    } else if (t == 'chatPosition') {
      _patchChatPosition(node);
    } else if (t == 'chat') {
      _patchChat(node);
    } else if (t == 'videoChat') {
      _patchVideoChat(node);
    } else if (t == 'message') {
      _patchMessage(node);
    } else if (t == 'user') {
      _patchUser(node);
    } else if (t == 'usernames') {
      _patchUsernames(node);
    } else if (t == 'profilePhoto') {
      _patchProfilePhoto(node);
    } else if (t == 'emojiStatus') {
      _patchEmojiStatus(node);
    } else if (t == 'userTypeBot') {
      _patchUserTypeBot(node);
    } else if (t == 'messageForwardInfo') {
      _patchMessageForwardInfo(node);
    } else if (t == 'messageSenderUser') {
      if (node['user_id'] == null) node['user_id'] = 0;
    } else if (t == 'messageSenderChat') {
      if (node['chat_id'] == null) node['chat_id'] = 0;
    } else if (t == 'reactionTypeEmoji') {
      _patchReactionTypeEmoji(node);
    } else if (t == 'reactionTypeCustomEmoji') {
      _patchReactionTypeCustomEmoji(node);
    } else if (t == 'userFullInfo') {
      _patchUserFullInfo(node);
    } else if (t == 'file') {
      _patchTdlibFile(node);
    } else if (t == 'minithumbnail') {
      _patchMinithumbnail(node);
    } else if (t == 'localFile') {
      _patchLocalFile(node);
    } else if (t == 'remoteFile') {
      _patchRemoteFile(node);
    }
    node.forEach((_, v) => _walk(v));
  } else if (node is List) {
    for (final e in node) {
      _walk(e);
    }
  }
}

/// Newer TDLib uses [name] (chatFolderName + formattedText); bindings expect [title] string.
void _patchChatFolderInfo(Map<String, dynamic> m) {
  if (m['title'] == null || (m['title'] is String && (m['title'] as String).isEmpty)) {
    final name = m['name'];
    if (name is String && name.isNotEmpty) {
      m['title'] = name;
    } else if (name is Map<String, dynamic>) {
      final text = name['text'];
      if (text is Map<String, dynamic>) {
        final inner = text['text'];
        m['title'] = inner is String ? inner : '';
      } else {
        m['title'] = '';
      }
    } else {
      m['title'] = '';
    }
  }
  if (m['is_shareable'] == null) m['is_shareable'] = false;
  if (m['has_my_invite_links'] == null) m['has_my_invite_links'] = false;
}

void _patchChatPermissions(Map<String, dynamic> p) {
  const keys = <String>[
    'can_send_basic_messages',
    'can_send_audios',
    'can_send_documents',
    'can_send_photos',
    'can_send_videos',
    'can_send_video_notes',
    'can_send_voice_notes',
    'can_send_polls',
    'can_send_other_messages',
    'can_add_web_page_previews',
    'can_change_info',
    'can_invite_users',
    'can_pin_messages',
    'can_manage_topics',
  ];
  for (final k in keys) {
    if (p[k] == null) p[k] = false;
  }
}

void _patchVideoChat(Map<String, dynamic> v) {
  if (v['has_participants'] == null) v['has_participants'] = false;
}

/// Newer TDLib adds fields; older bindings still require every legacy bool / string.
void _patchSupergroup(Map<String, dynamic> s) {
  if (s['member_count'] == null) s['member_count'] = 0;
  if (s['date'] == null) s['date'] = 0;
  if (s['restriction_reason'] == null) s['restriction_reason'] = '';
  const boolKeys = <String>[
    'has_linked_chat',
    'has_location',
    'sign_messages',
    'join_to_send_messages',
    'join_by_request',
    'is_slow_mode_enabled',
    'is_channel',
    'is_broadcast_group',
    'is_forum',
    'is_verified',
    'is_scam',
    'is_fake',
  ];
  for (final k in boolKeys) {
    if (s[k] == null) s[k] = false;
  }
}

void _patchChatTypeSupergroup(Map<String, dynamic> t) {
  if (t['is_channel'] == null) t['is_channel'] = false;
}

/// TDLib renamed story-sender preview fields; `package:tdlib` 1.6 expects *_story_sender*.
void _patchChatNotificationSettings(Map<String, dynamic> m) {
  if (m['use_default_show_story_sender'] == null &&
      m.containsKey('use_default_show_story_poster')) {
    m['use_default_show_story_sender'] = m['use_default_show_story_poster'];
  }
  if (m['show_story_sender'] == null && m.containsKey('show_story_poster')) {
    m['show_story_sender'] = m['show_story_poster'];
  }
  const boolKeys = <String>[
    'use_default_mute_for',
    'use_default_sound',
    'use_default_show_preview',
    'show_preview',
    'use_default_mute_stories',
    'mute_stories',
    'use_default_story_sound',
    'use_default_show_story_sender',
    'show_story_sender',
    'use_default_disable_pinned_message_notifications',
    'disable_pinned_message_notifications',
    'use_default_disable_mention_notifications',
    'disable_mention_notifications',
  ];
  for (final k in boolKeys) {
    if (m[k] == null) m[k] = false;
  }
  if (m['mute_for'] == null) m['mute_for'] = 0;
  _stringifyId(m, 'sound_id');
  _stringifyId(m, 'story_sound_id');
}

void _stringifyId(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v == null) {
    m[key] = '0';
  } else if (v is num) {
    m[key] = v.toString();
  }
}

/// New TDLib nests reactions under [messageReactions]; bindings expect a plain list.
void _patchMessageInteractionInfo(Map<String, dynamic> info) {
  final r = info['reactions'];
  if (r is Map<String, dynamic> && r['@type'] == 'messageReactions') {
    final inner = r['reactions'];
    info['reactions'] = inner is List ? inner : <dynamic>[];
  }
}

/// Newer TDLib may send [emoji] as [formattedText]; [ReactionTypeEmoji.fromJson] expects a [String].
void _patchReactionTypeEmoji(Map<String, dynamic> m) {
  final e = m['emoji'];
  if (e is String) return;
  m['emoji'] = _stringFromFormattedTextOrString(e);
}

/// [ReactionTypeCustomEmoji.fromJson] uses [int.parse] on [custom_emoji_id] (JSON string).
void _patchReactionTypeCustomEmoji(Map<String, dynamic> m) {
  final id = m['custom_emoji_id'];
  if (id == null) {
    m['custom_emoji_id'] = '0';
  } else if (id is num) {
    m['custom_emoji_id'] = id.toString();
  }
}

String _stringFromFormattedTextOrString(dynamic v) {
  if (v is String) return v;
  if (v is Map<String, dynamic>) {
    if (v['@type'] == 'formattedText') {
      final t = v['text'];
      return t is String ? t : '';
    }
    final nested = v['text'];
    if (nested is String) return nested;
    if (nested is Map<String, dynamic>) {
      final inner = nested['text'];
      return inner is String ? inner : '';
    }
  }
  return '';
}

void _patchChatPosition(Map<String, dynamic> p) {
  if (p['is_pinned'] == null) p['is_pinned'] = false;
  final ord = p['order'];
  if (ord is num) {
    p['order'] = ord.toString();
  } else if (ord == null) {
    p['order'] = '0';
  }
}

void _patchChat(Map<String, dynamic> c) {
  if (c['title'] == null) c['title'] = '';
  if (c['theme_name'] == null) c['theme_name'] = '';
  if (c['client_data'] == null) c['client_data'] = '';
  const boolKeys = <String>[
    'has_protected_content',
    'is_translatable',
    'is_marked_as_unread',
    'is_blocked',
    'has_scheduled_messages',
    'can_be_deleted_only_for_self',
    'can_be_deleted_for_all_users',
    'can_be_reported',
    'default_disable_notification',
  ];
  for (final k in boolKeys) {
    if (c[k] == null) c[k] = false;
  }
  for (final k in const [
    'unread_count',
    'last_read_inbox_message_id',
    'last_read_outbox_message_id',
    'unread_mention_count',
    'unread_reaction_count',
    'message_auto_delete_time',
    'reply_markup_message_id',
  ]) {
    if (c[k] == null) c[k] = 0;
  }
}

void _patchMessage(Map<String, dynamic> m) {
  const boolKeys = <String>[
    'is_outgoing',
    'is_pinned',
    'can_be_edited',
    'can_be_forwarded',
    'can_be_saved',
    'can_be_deleted_only_for_self',
    'can_be_deleted_for_all_users',
    'can_get_added_reactions',
    'can_get_statistics',
    'can_get_message_thread',
    'can_get_viewers',
    'can_get_media_timestamp_links',
    'can_report_reactions',
    'has_timestamped_media',
    'is_channel_post',
    'is_topic_message',
    'contains_unread_mention',
  ];
  for (final k in boolKeys) {
    if (m[k] == null) m[k] = false;
  }
  if (m['author_signature'] == null) m['author_signature'] = '';
  if (m['restriction_reason'] == null) m['restriction_reason'] = '';
  // [Message.fromJson] uses int.parse — value must be a JSON string.
  final albumId = m['media_album_id'];
  if (albumId == null) {
    m['media_album_id'] = '0';
  } else if (albumId is num) {
    m['media_album_id'] = albumId.toString();
  }
  if (m['message_thread_id'] == null) m['message_thread_id'] = 0;
  if (m['self_destruct_time'] == null) m['self_destruct_time'] = 0;
  if (m['self_destruct_in'] == null) {
    m['self_destruct_in'] = 0.0;
  } else if (m['self_destruct_in'] is int) {
    m['self_destruct_in'] = (m['self_destruct_in'] as int).toDouble();
  }
  if (m['auto_delete_in'] == null) {
    m['auto_delete_in'] = 0.0;
  } else if (m['auto_delete_in'] is int) {
    m['auto_delete_in'] = (m['auto_delete_in'] as int).toDouble();
  }
  if (m['via_bot_user_id'] == null) m['via_bot_user_id'] = 0;
  if (m['edit_date'] == null) m['edit_date'] = 0;
  if (m['id'] == null) m['id'] = 0;
  if (m['chat_id'] == null) m['chat_id'] = 0;
  if (m['date'] == null) m['date'] = 0;
}

void _patchUsernames(Map<String, dynamic> m) {
  m['active_usernames'] = _sanitizeStringList(m['active_usernames']);
  m['disabled_usernames'] = _sanitizeStringList(m['disabled_usernames']);
  if (m['editable_username'] != null) return;
  final active = m['active_usernames'];
  if (active is List && active.isNotEmpty && active.first is String) {
    m['editable_username'] = active.first;
  } else {
    m['editable_username'] = '';
  }
}

List<String> _sanitizeStringList(dynamic value) {
  if (value is! List) return <String>[];
  return value.whereType<String>().toList();
}

/// [ProfilePhoto.fromJson] uses [int.parse] on [id] (JSON string).
void _patchProfilePhoto(Map<String, dynamic> p) {
  final id = p['id'];
  if (id == null) {
    p['id'] = '0';
  } else if (id is int) {
    p['id'] = id.toString();
  }
  if (p['has_animation'] == null) p['has_animation'] = false;
  if (p['is_personal'] == null) p['is_personal'] = false;
}

void _patchEmojiStatus(Map<String, dynamic> e) {
  final id = e['custom_emoji_id'];
  if (id == null) {
    e['custom_emoji_id'] = '0';
  } else if (id is num) {
    e['custom_emoji_id'] = id.toString();
  }
  if (e['expiration_date'] == null) e['expiration_date'] = 0;
}

void _patchUserTypeBot(Map<String, dynamic> u) {
  if (u['inline_query_placeholder'] == null) {
    u['inline_query_placeholder'] = '';
  }
}

void _patchMessageForwardInfo(Map<String, dynamic> m) {
  if (m['date'] == null) m['date'] = 0;
  if (m['public_service_announcement_type'] == null) {
    m['public_service_announcement_type'] = '';
  }
  if (m['from_chat_id'] == null) m['from_chat_id'] = 0;
  if (m['from_message_id'] == null) m['from_message_id'] = 0;
}

void _patchUserFullInfo(Map<String, dynamic> m) {
  // Newer TDLib renamed / split story flags; bindings 1.6 still expect has_pinned_stories.
  if (m['has_pinned_stories'] == null && m.containsKey('has_posted_to_profile_stories')) {
    m['has_pinned_stories'] = m['has_posted_to_profile_stories'];
  }
  const boolKeys = <String>[
    'is_blocked',
    'can_be_called',
    'supports_video_calls',
    'has_private_calls',
    'has_private_forwards',
    'has_restricted_voice_and_video_note_messages',
    'has_pinned_stories',
    'need_phone_number_privacy_exception',
  ];
  for (final k in boolKeys) {
    if (m[k] == null) m[k] = false;
  }
  if (m['group_in_common_count'] == null) m['group_in_common_count'] = 0;
  if (m['premium_gift_options'] == null) m['premium_gift_options'] = <dynamic>[];
}

void _patchUser(Map<String, dynamic> u) {
  const boolKeys = <String>[
    'is_contact',
    'is_mutual_contact',
    'is_close_friend',
    'is_verified',
    'is_premium',
    'is_support',
    'is_scam',
    'is_fake',
    'has_active_stories',
    'has_unread_active_stories',
    'have_access',
    'added_to_attachment_menu',
  ];
  for (final k in boolKeys) {
    if (u[k] == null) u[k] = false;
  }
  if (u['restriction_reason'] == null) u['restriction_reason'] = '';
  if (u['language_code'] == null) u['language_code'] = '';
  if (u['phone_number'] == null) u['phone_number'] = '';
  if (u['first_name'] == null) u['first_name'] = '';
  if (u['last_name'] == null) u['last_name'] = '';
  if (u['type'] == null) {
    u['type'] = <String, dynamic>{'@type': 'userTypeRegular'};
  }
}

/// [File.local] / [File.remote] must be non-null for [File.fromJson].
void _patchTdlibFile(Map<String, dynamic> f) {
  if (f['id'] == null) f['id'] = 0;
  if (f['size'] == null) f['size'] = 0;
  if (f['expected_size'] == null) f['expected_size'] = 0;
  if (f['local'] == null) {
    f['local'] = <String, dynamic>{
      '@type': 'localFile',
      'path': '',
      'can_be_downloaded': false,
      'can_be_deleted': false,
      'is_downloading_active': false,
      'is_downloading_completed': false,
      'download_offset': 0,
      'downloaded_prefix_size': 0,
      'downloaded_size': 0,
    };
  }
  if (f['remote'] == null) {
    f['remote'] = <String, dynamic>{
      '@type': 'remoteFile',
      'id': '',
      'unique_id': '',
      'is_uploading_active': false,
      'is_uploading_completed': false,
      'uploaded_size': 0,
    };
  }
}

void _patchMinithumbnail(Map<String, dynamic> m) {
  if (m['width'] == null) m['width'] = 0;
  if (m['height'] == null) m['height'] = 0;
  if (m['data'] == null) m['data'] = '';
}

void _patchLocalFile(Map<String, dynamic> f) {
  for (final k in const [
    'can_be_downloaded',
    'can_be_deleted',
    'is_downloading_active',
    'is_downloading_completed',
  ]) {
    if (f[k] == null) f[k] = false;
  }
  for (final k in const ['download_offset', 'downloaded_prefix_size', 'downloaded_size']) {
    if (f[k] == null) f[k] = 0;
  }
  if (f['path'] == null) f['path'] = '';
}

void _patchRemoteFile(Map<String, dynamic> f) {
  for (final k in const ['is_uploading_active', 'is_uploading_completed']) {
    if (f[k] == null) f[k] = false;
  }
  if (f['id'] == null) f['id'] = '';
  if (f['unique_id'] == null) f['unique_id'] = '';
  if (f['uploaded_size'] == null) f['uploaded_size'] = 0;
}
