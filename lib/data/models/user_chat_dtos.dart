/// API rows for GET [/me/chats] and related source-chat endpoints.
class UserChatRow {
  const UserChatRow({
    required this.id,
    required this.telegramChatId,
    required this.title,
    this.photoUrl,
    required this.chatType,
    required this.peerIsBot,
    required this.isIndexed,
    this.lastIndexedMessageId,
  });

  final String id;
  final String telegramChatId;
  final String title;
  final String? photoUrl;
  final String chatType;
  final bool peerIsBot;
  final bool isIndexed;
  final String? lastIndexedMessageId;

  factory UserChatRow.fromJson(Map<String, dynamic> json) {
    return UserChatRow(
      id: (json['id'] ?? '').toString(),
      telegramChatId: (json['telegramChatId'] ?? json['telegram_chat_id'] ?? '')
          .toString(),
      title: (json['title'] ?? '').toString(),
      photoUrl: json['photoUrl']?.toString() ?? json['photo_url']?.toString(),
      chatType: (json['chatType'] ?? json['chat_type'] ?? 'private').toString(),
      peerIsBot:
          json['peerIsBot'] == true || json['peer_is_bot'] == true,
      isIndexed: json['isIndexed'] == true || json['is_indexed'] == true,
      lastIndexedMessageId: json['lastIndexedMessageId']?.toString() ??
          json['last_indexed_message_id']?.toString(),
    );
  }
}

class UserChatListPage {
  const UserChatListPage({
    required this.items,
    required this.total,
  });

  final List<UserChatRow> items;
  final int total;

  factory UserChatListPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final list = <UserChatRow>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          list.add(UserChatRow.fromJson(e));
        }
      }
    }
    final t = json['total'];
    final total = t is int ? t : int.tryParse(t?.toString() ?? '') ?? list.length;
    return UserChatListPage(items: list, total: total);
  }
}

class SourceChatMediaRow {
  const SourceChatMediaRow({
    required this.fileId,
    required this.messageId,
    this.remoteFileId,
    this.caption,
    this.messageDate,
    required this.telegramChatId,
  });

  final String fileId;
  final String messageId;
  final String? remoteFileId;
  final String? caption;
  final DateTime? messageDate;
  final String telegramChatId;

  factory SourceChatMediaRow.fromJson(Map<String, dynamic> json) {
    final md = json['messageDate'] ?? json['message_date'];
    return SourceChatMediaRow(
      fileId: (json['fileId'] ?? json['file_id'] ?? '').toString(),
      messageId: (json['messageId'] ?? json['message_id'] ?? '').toString(),
      remoteFileId: json['remoteFileId']?.toString() ??
          json['remote_file_id']?.toString(),
      caption: json['caption']?.toString(),
      messageDate: md != null ? DateTime.tryParse(md.toString()) : null,
      telegramChatId: (json['telegramChatId'] ?? json['telegram_chat_id'] ?? '')
          .toString(),
    );
  }
}

class SourceChatMediaPage {
  const SourceChatMediaPage({
    required this.items,
    required this.total,
  });

  final List<SourceChatMediaRow> items;
  final int total;

  factory SourceChatMediaPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final list = <SourceChatMediaRow>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          list.add(SourceChatMediaRow.fromJson(e));
        }
      }
    }
    final t = json['total'];
    final total = t is int ? t : int.tryParse(t?.toString() ?? '') ?? list.length;
    return SourceChatMediaPage(items: list, total: total);
  }
}
