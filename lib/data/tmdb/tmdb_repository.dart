import 'package:tmdb_api/tmdb_api.dart';

import '../../core/config/app_config.dart';

/// TMDB metadata with the same poster sizing policy as `tv-app-old` (`w500`).
class TmdbRepository {
  TmdbRepository({required AppConfig config})
      : _tmdb = TMDB(
          ApiKeys(config.tmdbApiKey, ''),
        );

  final TMDB _tmdb;

  final Map<String, Map<String, dynamic>> _lru = {};
  static const int _lruCap = 100;

  static String posterUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    return 'https://image.tmdb.org/t/p/w500$path';
  }

  Future<Map<String, dynamic>?> findByImdbId(String rawImdbId) async {
    final imdbId = rawImdbId.startsWith('tt') ? rawImdbId : 'tt$rawImdbId';
    final cached = _lru[imdbId];
    if (cached != null) return cached;

    final raw = await _tmdb.v3.find.getById(imdbId);
    final data = Map<String, dynamic>.from(raw);
    final movie = _firstResultMap(data, 'movie_results');
    final tv = _firstResultMap(data, 'tv_results');
    final result = movie ?? tv;
    if (result != null) {
      _put(imdbId, result);
    }
    return result;
  }

  static Map<String, dynamic>? _firstResultMap(Map<String, dynamic> data, String key) {
    final v = data[key];
    if (v is! List || v.isEmpty) return null;
    final first = v.first;
    if (first is Map<String, dynamic>) return first;
    if (first is Map) return first.cast<String, dynamic>();
    return null;
  }

  void _put(String key, Map<String, dynamic> value) {
    if (_lru.length >= _lruCap) {
      final first = _lru.keys.first;
      _lru.remove(first);
    }
    _lru[key] = value;
  }
}
