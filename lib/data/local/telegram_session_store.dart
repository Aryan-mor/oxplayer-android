import 'package:isar/isar.dart';
import 'package:tdlib/td_api.dart' as td;

import 'entities.dart';

String? _primaryUsername(td.User user) {
  final u = user.usernames;
  if (u == null) return null;
  if (u.activeUsernames.isNotEmpty) return u.activeUsernames.first;
  if (u.editableUsername.isNotEmpty) return u.editableUsername;
  return null;
}

/// Upserts the singleton TDLib session row (id / [singletonKey] = 1).
Future<void> putTelegramSessionFromUser(Isar isar, td.User user) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final row = TelegramSession()
    ..id = 1
    ..singletonKey = 1
    ..userId = user.id
    ..firstName = user.firstName
    ..username = _primaryUsername(user)
    ..updatedAt = now;
  await isar.writeTxn(() async {
    await isar.telegramSessions.put(row);
  });
}
