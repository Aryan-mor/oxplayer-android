import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists [Media.id] values parsed from `${INDEX_TAG}_M_<id>` in captions (no Telegram file required).
class DiscoveryMediaIdsStore {
  DiscoveryMediaIdsStore._();

  static const _prefsKey = 'telecima.discovery_media_ids_v1';

  /// Matches server [DECIMAL_ID_REGEX] / Prisma [Media.id] (BIGINT).
  static final _numericMediaId = RegExp(r'^\d{1,19}$');

  static Future<void> pruneInvalid() async {
    final prefs = await SharedPreferences.getInstance();
    final set = await _loadSet(prefs);
    set.removeWhere((id) => !_numericMediaId.hasMatch(id.trim()));
    await _saveSet(prefs, set);
  }

  static Future<void> merge(Set<String> ids) async {
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final set = await _loadSet(prefs);
    for (final id in ids) {
      final t = id.trim();
      if (_numericMediaId.hasMatch(t)) set.add(t);
    }
    await _saveSet(prefs, set);
  }

  static Future<Set<String>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadSet(prefs);
  }

  static Future<Set<String>> _loadSet(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.map((e) => e.toString().trim()).where(_numericMediaId.hasMatch).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _saveSet(SharedPreferences prefs, Set<String> set) async {
    await prefs.setString(_prefsKey, jsonEncode(set.toList()..sort()));
  }
}
