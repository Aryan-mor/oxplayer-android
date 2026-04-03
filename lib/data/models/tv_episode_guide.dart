/// Response from GET [/me/media/:id/tv-episode-guide].
class TvEpisodeGuide {
  TvEpisodeGuide({required this.seasons});

  final List<TvGuideSeason> seasons;

  bool get isEmpty => seasons.isEmpty;

  factory TvEpisodeGuide.fromJson(Map<String, dynamic> json) {
    final raw = json['seasons'];
    final list = <TvGuideSeason>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          list.add(TvGuideSeason.fromJson(e));
        }
      }
    }
    return TvEpisodeGuide(seasons: list);
  }
}

class TvGuideSeason {
  TvGuideSeason({required this.seasonNumber, required this.episodes});

  final int seasonNumber;
  final List<TvGuideEpisode> episodes;

  factory TvGuideSeason.fromJson(Map<String, dynamic> json) {
    final sn = json['seasonNumber'] ?? json['season_number'];
    final seasonNumber = sn is int ? sn : int.tryParse(sn?.toString() ?? '') ?? 0;
    final raw = json['episodes'];
    final eps = <TvGuideEpisode>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          eps.add(TvGuideEpisode.fromJson(e));
        }
      }
    }
    return TvGuideSeason(seasonNumber: seasonNumber, episodes: eps);
  }
}

class TvGuideEpisode {
  TvGuideEpisode({
    required this.episodeNumber,
    this.name,
    this.stillPath,
  });

  final int episodeNumber;
  final String? name;
  final String? stillPath;

  factory TvGuideEpisode.fromJson(Map<String, dynamic> json) {
    final en = json['episodeNumber'] ?? json['episode_number'];
    final episodeNumber = en is int ? en : int.tryParse(en?.toString() ?? '') ?? 0;
    final n = json['name']?.toString().trim();
    final sp = json['stillPath']?.toString() ?? json['still_path']?.toString();
    return TvGuideEpisode(
      episodeNumber: episodeNumber,
      name: n != null && n.isNotEmpty ? n : null,
      stillPath: sp != null && sp.trim().isNotEmpty ? sp.trim() : null,
    );
  }
}
