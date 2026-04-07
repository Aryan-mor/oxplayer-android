import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Disk cache for source-picker chat list snapshot and chat avatar files.
class SourcesLocalCache {
  SourcesLocalCache._();

  static final SourcesLocalCache instance = SourcesLocalCache._();

  Directory? _root;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'oxplayer', 'sources'));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  Future<File> _avatarFile(int telegramChatId) async {
    final root = await _ensureRoot();
    return File(p.join(root.path, 'avatar_$telegramChatId.jpg'));
  }

  Future<String?> readAvatarPathIfExists(int telegramChatId) async {
    final f = await _avatarFile(telegramChatId);
    if (f.existsSync()) return f.path;
    return null;
  }

  Future<void> writeAvatarJpeg(int telegramChatId, List<int> bytes) async {
    if (bytes.isEmpty) return;
    final f = await _avatarFile(telegramChatId);
    await f.writeAsBytes(bytes, flush: true);
  }

  Future<void> saveChatOrderSnapshot(List<int> chatIds) async {
    final root = await _ensureRoot();
    final f = File(p.join(root.path, 'chat_order.json'));
    await f.writeAsString(
      jsonEncode(<String, dynamic>{'chatIds': chatIds}),
      flush: true,
    );
  }

  Future<List<int>> readChatOrderSnapshot() async {
    final root = await _ensureRoot();
    final f = File(p.join(root.path, 'chat_order.json'));
    if (!f.existsSync()) return const [];
    try {
      final map = jsonDecode(f.readAsStringSync());
      if (map is! Map) return const [];
      final raw = map['chatIds'];
      if (raw is! List) return const [];
      return raw.map((e) => int.tryParse(e.toString()) ?? 0).where((e) => e != 0).toList();
    } catch (_) {
      return const [];
    }
  }
}
