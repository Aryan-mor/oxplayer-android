import 'package:oxplayer/models/plex_media_version.dart';
import 'package:oxplayer/models/plex_metadata.dart';
import 'package:oxplayer/models/plex_role.dart';
import 'package:oxplayer/services/settings_service.dart';

import '../../infrastructure/data_repository.dart';

/// [PlexMetadata] adapter for a Telegram chat video row (grid + detail).
class TelegramVideoMetadata implements PlexMetadata {
  TelegramVideoMetadata(this.row, this.thumbnailPath);

  final OxChatMediaRow row;
  final String thumbnailPath;

  static final RegExp _newline = RegExp(r'\r?\n');

  @override
  String get ratingKey => 'telegram_${row.fileId}_${row.messageId}';

  @override
  String? get key => null;

  @override
  String? get guid => null;

  @override
  String? get studio => 'Telegram';

  @override
  String? get type => 'video';

  String get _fileLabel {
    final n = row.fileName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return 'Video ${row.messageId}';
  }

  @override
  String? get title => displayTitle;

  @override
  String get displayTitle {
    final cap = row.caption?.trim();
    if (cap != null && cap.isNotEmpty) {
      final first = cap.split(_newline).first.trim();
      if (first.isNotEmpty) return first;
    }
    return _fileLabel;
  }

  @override
  String? get titleSort => displayTitle;

  @override
  String? get contentRating => null;

  @override
  String? get summary {
    final cap = row.caption?.trim();
    if (cap == null || cap.isEmpty) return null;
    final lines = cap.split(_newline);
    if (lines.length > 1) {
      final rest = lines.skip(1).join('\n').trim();
      return rest.isEmpty ? null : rest;
    }
    return null;
  }

  @override
  String? get displaySubtitle {
    final cap = row.caption?.trim();
    if (cap == null || cap.isEmpty) return null;
    final fn = row.fileName?.trim();
    if (fn == null || fn.isEmpty) return null;
    if (fn == displayTitle) return null;
    final hasMoreBody = cap.split(_newline).length > 1 || cap.length > 72;
    return hasMoreBody ? '$fn · …' : fn;
  }

  @override
  double? get rating => null;

  @override
  double? get audienceRating => null;

  @override
  double? get userRating => null;

  @override
  int? get year => null;

  @override
  String? get originallyAvailableAt => row.messageDate?.split('T')[0];

  @override
  String? get thumb => thumbnailPath.isNotEmpty ? thumbnailPath : null;

  @override
  String? get art => null;

  @override
  int? get duration => row.durationSeconds != null && row.durationSeconds! > 0 ? row.durationSeconds! * 1000 : null;

  @override
  int? get addedAt => null;

  @override
  int? get updatedAt => null;

  @override
  int? get lastViewedAt => null;

  @override
  String? get grandparentTitle => null;

  @override
  String? get grandparentThumb => null;

  @override
  String? get grandparentArt => null;

  @override
  String? get grandparentRatingKey => null;

  @override
  String? get parentTitle => null;

  @override
  String? get parentThumb => null;

  @override
  String? get parentRatingKey => null;

  @override
  int? get parentIndex => null;

  @override
  int? get index => int.tryParse(row.messageId);

  @override
  String? get grandparentTheme => null;

  @override
  int? get viewOffset => null;

  @override
  int? get viewCount => null;

  @override
  int? get leafCount => null;

  @override
  int? get viewedLeafCount => null;

  @override
  int? get childCount => null;

  @override
  List<PlexRole>? get role => null;

  @override
  List<PlexMediaVersion>? get mediaVersions => null;

  @override
  List<String>? get genre => null;

  @override
  List<String>? get director => null;

  @override
  List<String>? get writer => null;

  @override
  List<String>? get producer => null;

  @override
  List<String>? get country => null;

  @override
  List<String>? get collection => null;

  @override
  List<String>? get label => null;

  @override
  List<String>? get style => null;

  @override
  List<String>? get mood => null;

  @override
  String? get audioLanguage => null;

  @override
  String? get subtitleLanguage => null;

  @override
  int? get subtitleMode => null;

  @override
  int? get playlistItemID => null;

  @override
  int? get playQueueItemID => null;

  @override
  int? get librarySectionID => null;

  @override
  String? get librarySectionTitle => null;

  @override
  String? get ratingImage => null;

  @override
  String? get audienceRatingImage => null;

  @override
  String? get tagline => null;

  @override
  String? get originalTitle => null;

  @override
  String? get editionTitle => null;

  @override
  String? get subtype => null;

  @override
  int? get extraType => null;

  @override
  String? get primaryExtraKey => null;

  @override
  String? get serverId => 'telegram';

  @override
  String? get serverName => 'Telegram';

  @override
  String? get clearLogo => null;

  @override
  String? get backgroundSquare => null;

  @override
  bool get isLibrarySection => false;

  @override
  PlexMetadata copyWith({
    String? ratingKey,
    String? key,
    String? guid,
    String? studio,
    String? type,
    String? title,
    String? titleSort,
    String? contentRating,
    String? summary,
    double? rating,
    double? audienceRating,
    double? userRating,
    int? year,
    String? originallyAvailableAt,
    String? thumb,
    String? art,
    int? duration,
    int? addedAt,
    int? updatedAt,
    int? lastViewedAt,
    String? grandparentTitle,
    String? grandparentThumb,
    String? grandparentArt,
    String? grandparentRatingKey,
    String? parentTitle,
    String? parentThumb,
    String? parentRatingKey,
    int? parentIndex,
    int? index,
    String? grandparentTheme,
    int? viewOffset,
    int? viewCount,
    int? leafCount,
    int? viewedLeafCount,
    int? childCount,
    List<PlexRole>? role,
    List<PlexMediaVersion>? mediaVersions,
    List<String>? genre,
    List<String>? director,
    List<String>? writer,
    List<String>? producer,
    List<String>? country,
    List<String>? collection,
    List<String>? label,
    List<String>? style,
    List<String>? mood,
    String? audioLanguage,
    String? subtitleLanguage,
    int? subtitleMode,
    int? playlistItemID,
    int? playQueueItemID,
    int? librarySectionID,
    String? librarySectionTitle,
    String? ratingImage,
    String? audienceRatingImage,
    String? tagline,
    String? originalTitle,
    String? editionTitle,
    String? subtype,
    int? extraType,
    String? primaryExtraKey,
    String? serverId,
    String? serverName,
    String? clearLogo,
    String? backgroundSquare,
  }) {
    return TelegramVideoMetadata(row, thumbnailPath);
  }

  @override
  String? heroArt({required double containerAspectRatio}) => null;

  @override
  String? posterThumb({EpisodePosterMode mode = EpisodePosterMode.seriesPoster, bool mixedHubContext = false}) =>
      thumbnailPath.isNotEmpty ? thumbnailPath : null;

  @override
  Map<String, dynamic> toJson() => {};

  @override
  String get globalKey => ratingKey;

  @override
  bool get hasActiveProgress => false;

  @override
  bool get isWatched => false;

  @override
  String? get librarySectionKey => null;

  @override
  PlexMediaType get mediaType => PlexMediaType.movie;

  bool get shouldHideSpoiler => false;

  @override
  bool usesWideAspectRatio(EpisodePosterMode mode, {bool mixedHubContext = false}) => false;

  @override
  (int?, int?) get subdlSeasonEpisodeNumbers => (null, null);
}
