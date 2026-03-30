import 'package:isar/isar.dart';

part 'entities.g.dart';

// ─── Season / Episode ────────────────────────────────────────────────────────

/// One season of a #series MediaItem.
@collection
class MediaSeason {
  Id id = Isar.autoIncrement;

  /// Links to [MediaItem.globalId].
  @Index()
  late String globalId;

  @Index(unique: true, replace: true)
  late String seasonKey; // "$globalId:S$seasonNumber"

  late int seasonNumber;
  String? title; // e.g. "Season 1" or explicit from tag
  late int episodeCount; // filled / updated as episodes arrive
}

/// One episode within a [MediaSeason].
@collection
class MediaEpisode {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String episodeKey; // "$globalId:S$sN:E$eN"

  @Index()
  late String globalId;

  @Index()
  late String seasonKey; // FK to [MediaSeason.seasonKey]

  late int seasonNumber;
  late int episodeNumber;

  String? title;
  String? variantId; // FK to [MediaVariant.variantId]
  int? msgId;
  int? chatId;
  int? fileSize;
  int? durationSec;
}

@collection
class MediaSource {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late int sourceId;

  late String name;
  String? imagePath;
}

/// Mirrors [tv-app-old] Dexie `MediaItem` (IndexedDB).
@collection
class MediaItem {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String globalId;

  late String title;
  late String imdbId;
  String? tmdbId;

  /// Stored as `#movie` | `#series` (same as the web app).
  late String mediaType;

  late List<String> genres;
  late List<String> tags;

  String? posterUrl;
  String? backdropUrl;

  @Index()
  late int mediaSourceId;

  late int lastMsgId;

  @Index()
  late int lastSyncedAt;

  late int variantsCount;
  String? bestVariantId;

  late bool streamSupported;
  late bool isPremiumNeeded;

  int? bitrateEstimate;
  int? metaCachedAt;
}

/// Mirrors Dexie `MediaVariant`.
@collection
class MediaVariant {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String variantId;

  @Index()
  late String globalId;

  late int msgId;
  late int chatId;

  late String sourceScope;

  String? fileName;
  String? mimeType;
  int? fileSize;
  int? durationSec;
  String? qualityLabel;
  int? bitrateEstimate;

  late bool streamSupported;
  late bool isPremiumNeeded;

  /// Optional JSON blob for TDLib/Gram parity (web stored `unknown`).
  String? fileReferenceJson;

  late int createdAt;
}

/// Mirrors Dexie `SyncCheckpoint`.
@collection
class SyncCheckpoint {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String dialogKey;

  late String scope;
  late int dialogId;
  String? dialogTitle;

  late int lastMessageId;
  late int lastSyncAt;

  late String status;
  String? lastError;
}

/// Mirrors Dexie `DownloadManifest` (local path instead of OPFS).
@collection
class MediaDownload {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String downloadId;

  @Index()
  late String globalId;

  @Index()
  late String variantId;

  late String fileName;
  late String status;

  late int bytesDownloaded;
  int? totalBytes;
  late int updatedAt;

  String? errorMessage;
  String? mimeType;

  /// Completed downloads: absolute path on device storage.
  String? localFilePath;

  /// Standardized filename used for file-existence checks (e.g. "Interstellar_2014.mkv").
  @Index()
  String? standardizedName;

  /// TDLib internal file id, used to track [updateFile] progress events.
  int? tdlibFileId;
}

/// Singleton row: persisted TDLib login (user id from [AuthorizationStateReady] + [getMe]).
@collection
class TelegramSession {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late int singletonKey;

  late int userId;

  String? firstName;
  String? username;

  @Index()
  late int updatedAt;
}
