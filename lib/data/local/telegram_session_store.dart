import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;

String? _primaryUsername(td.User user) {
  final u = user.usernames;
  if (u == null) return null;
  if (u.activeUsernames.isNotEmpty) return u.activeUsernames.first;
  if (u.editableUsername.isNotEmpty) return u.editableUsername;
  return null;
}

/// Upserts the singleton TDLib session row via SharedPreferences.
Future<void> putTelegramSessionFromUser(td.User user) async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now().millisecondsSinceEpoch;
  
  final sessionData = {
    'userId': user.id,
    'firstName': user.firstName,
    'username': _primaryUsername(user),
    'updatedAt': now,
  };
  
  await prefs.setString('telegram_session', jsonEncode(sessionData));
}

/// Clears the singleton TDLib session row.
Future<void> clearTelegramSession() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('telegram_session');
}

