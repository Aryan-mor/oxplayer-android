import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'tv_app_api_service.dart';

/// Persists [DiscoveredMediaRef] from successful Telegram searches so we can
/// call [/me/sync] again after incremental [minDate] returns zero hits — otherwise
/// [user_file_locators] are never upserted and downloads stay broken.
class DiscoveryRefsStore {
  DiscoveryRefsStore._();

  static const _prefsKey = 'telecima.discovery_refs_v1';

  static Future<void> merge(List<DiscoveredMediaRef> batch) async {
    if (batch.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadMap(prefs);
    for (final r in batch) {
      final tf = r.telegramFileId?.trim() ?? '';
      if (tf.isEmpty) continue;
      final existing = map[r.mediaFileId];
      final prevDate = (existing?['telegramDate'] as num?)?.toInt() ?? 0;
      if (existing == null || r.telegramDate >= prevDate) {
        map[r.mediaFileId] = r.toPersistenceJson();
      }
    }
    await prefs.setString(_prefsKey, jsonEncode(map));
  }

  static Future<List<DiscoveredMediaRef>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadMap(prefs);
    final out = <DiscoveredMediaRef>[];
    for (final e in map.entries) {
      final r = DiscoveredMediaRef.fromPersistenceJson(e.value);
      if (r != null) out.add(r);
    }
    return out;
  }

  static Future<Map<String, Map<String, dynamic>>> _loadMap(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, Map<String, dynamic>>{};
      for (final e in decoded.entries) {
        final k = e.key.toString();
        final v = e.value;
        if (v is Map<String, dynamic>) {
          out[k] = v;
        } else if (v is Map) {
          out[k] = Map<String, dynamic>.from(v);
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }
}
