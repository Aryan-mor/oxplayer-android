/// Response from GET [/me/media/:id/tv-episode-guide] (series episode metadata from backend).
class SeriesEpisodeGuide {
  SeriesEpisodeGuide({required this.seasons});

  final List<SeriesGuideSeason> seasons;

  bool get isEmpty => seasons.isEmpty;

  factory SeriesEpisodeGuide.fromJson(Map<String, dynamic> json) {
    final raw = json['seasons'];
    final list = <SeriesGuideSeason>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          list.add(SeriesGuideSeason.fromJson(e));
        }
      }
    }
    return SeriesEpisodeGuide(seasons: list);
  }
}

class SeriesGuideSeason {
  SeriesGuideSeason({required this.seasonNumber, required this.episodes});

  final int seasonNumber;
  final List<SeriesGuideEpisode> episodes;

  factory SeriesGuideSeason.fromJson(Map<String, dynamic> json) {
    final sn = json['seasonNumber'] ?? json['season_number'];
    final seasonNumber = sn is int ? sn : int.tryParse(sn?.toString() ?? '') ?? 0;
    final raw = json['episodes'];
    final eps = <SeriesGuideEpisode>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          eps.add(SeriesGuideEpisode.fromJson(e));
        }
      }
    }
    return SeriesGuideSeason(seasonNumber: seasonNumber, episodes: eps);
  }
}

class SeriesGuideEpisode {
  SeriesGuideEpisode({
    required this.episodeNumber,
    this.name,
    this.stillPath,
    this.overview,
  });

  final int episodeNumber;
  final String? name;
  final String? stillPath;
  /// TMDB episode overview when the API includes it.
  final String? overview;

  factory SeriesGuideEpisode.fromJson(Map<String, dynamic> json) {
    final en = json['episodeNumber'] ?? json['episode_number'];
    final episodeNumber = en is int ? en : int.tryParse(en?.toString() ?? '') ?? 0;
    final n = json['name']?.toString().trim();
    final sp = json['stillPath']?.toString() ?? json['still_path']?.toString();
    final ov = json['overview']?.toString().trim();
    return SeriesGuideEpisode(
      episodeNumber: episodeNumber,
      name: n != null && n.isNotEmpty ? n : null,
      stillPath: sp != null && sp.trim().isNotEmpty ? sp.trim() : null,
      overview: ov != null && ov.isNotEmpty ? ov : null,
    );
  }
}

