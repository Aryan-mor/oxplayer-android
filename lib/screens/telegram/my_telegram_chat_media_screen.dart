import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:oxplayer/models/plex_media_version.dart';
import 'package:oxplayer/models/plex_metadata.dart';
import 'package:oxplayer/models/plex_role.dart';
import 'package:oxplayer/providers/settings_provider.dart';
import 'package:oxplayer/services/settings_service.dart';
import 'package:oxplayer/theme/mono_tokens.dart';
import 'package:oxplayer/utils/grid_size_calculator.dart';
import 'package:oxplayer/utils/layout_constants.dart';
import 'package:oxplayer/widgets/app_icon.dart';
import 'package:oxplayer/widgets/focusable_media_card.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../infrastructure/data_repository.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/video_player_navigation.dart';

/// In-memory cache for one app session: reopening the same chat shows the last grid without refetching TDLib.
class _TelegramChatMediaSessionCache {
  _TelegramChatMediaSessionCache._();

  static final Map<String, _TelegramChatMediaCacheEntry> _byChatId = {};

  static String _key(String tdlibChatId, int messageThreadId, bool libraryIndexed) =>
      '${tdlibChatId.trim()}_${messageThreadId}_${libraryIndexed ? 'lib' : 'td'}';

  static _TelegramChatMediaCacheEntry? read(
    String tdlibChatId,
    int messageThreadId,
    bool libraryIndexed,
  ) =>
      _byChatId[_key(tdlibChatId, messageThreadId, libraryIndexed)];

  static void put({
    required String tdlibChatId,
    int messageThreadId = 0,
    bool libraryIndexed = false,
    required List<TelegramVideoMetadata> videos,
    required Map<String, String?> thumbnails,
    required bool hasMoreHistory,
    required int? nextHistoryFromMessageId,
    required bool liveUsesDocumentFilter,
  }) {
    _byChatId[_key(tdlibChatId, messageThreadId, libraryIndexed)] = _TelegramChatMediaCacheEntry(
      videos: List<TelegramVideoMetadata>.from(videos),
      thumbnails: Map<String, String?>.from(thumbnails),
      hasMoreHistory: hasMoreHistory,
      nextHistoryFromMessageId: nextHistoryFromMessageId,
      liveUsesDocumentFilter: liveUsesDocumentFilter,
    );
  }
}

class _TelegramChatMediaCacheEntry {
  const _TelegramChatMediaCacheEntry({
    required this.videos,
    required this.thumbnails,
    required this.hasMoreHistory,
    required this.nextHistoryFromMessageId,
    this.liveUsesDocumentFilter = false,
  });

  final List<TelegramVideoMetadata> videos;
  final Map<String, String?> thumbnails;
  final bool hasMoreHistory;
  final int? nextHistoryFromMessageId;

  /// Matches [OxChatMediaPage.liveSearchUsesDocumentFilter] for TDLib pagination.
  final bool liveUsesDocumentFilter;
}

/// Lists video messages from TDLib chat history using the same [FocusableMediaCard] / [MediaCard] as home hubs.

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

  // Required abstract method implementations
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

  // Additional required properties

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

/// Telegram chat/topic media grid ([ListView] or [CustomScrollView]).
///
/// Uses a [KeyedSubtree] so the [Key] must include [tdlibChatId] and [messageThreadId]; otherwise
/// Flutter can reuse scroll state when switching forum topics or chats.
class _GalleryGrid extends StatelessWidget {
  const _GalleryGrid({
    required this.tdlibChatId,
    required this.messageThreadId,
    required this.libraryIndexed,
    required this.child,
  });

  final String tdlibChatId;
  final int messageThreadId;
  final bool libraryIndexed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey<String>('tg_gallery_${tdlibChatId}_${messageThreadId}_$libraryIndexed'),
      child: child,
    );
  }
}

class MyTelegramChatMediaScreen extends StatefulWidget {
  const MyTelegramChatMediaScreen({
    super.key,
    required this.chatTitle,
    required this.tdlibChatId,
    this.messageThreadId = 0,
    this.embedInTabView = false,
    this.libraryIndexed = false,
  });

  final String chatTitle;
  final String tdlibChatId;

  /// Forum topic thread (`message_thread_id`); `0` = whole chat (non-forum).
  final int messageThreadId;

  /// When true, omits [Scaffold] app bar (used inside [MyTelegramForumTopicsScreen] tabs).
  final bool embedInTabView;

  /// When true with [embedInTabView], lists server-indexed `File` rows for this topic (`GET .../media?messageThreadId=`).
  final bool libraryIndexed;

  @override
  State<MyTelegramChatMediaScreen> createState() => _MyTelegramChatMediaScreenState();
}

enum _MyTgDlPhase { idle, downloading, paused, completed }

class _MyTgItemUiState {
  _MyTgItemUiState({
    this.phase = _MyTgDlPhase.idle,
    this.progress = 0,
    this.fileId,
    this.resumeOffset = 0,
    this.localPath,
    this.cancelRequested = false,
  });

  _MyTgDlPhase phase;
  double progress;
  int? fileId;
  int resumeOffset;
  String? localPath;
  bool cancelRequested;
}

class _MyTelegramChatMediaScreenState extends State<MyTelegramChatMediaScreen> {
  /// Live gallery: fixed 20 messages per [searchChatMessages] batch (My Telegram directive).
  static const int _pageSize = 20;

  final List<TelegramVideoMetadata> _items = [];
  final Map<String, String?> _thumbnailCache = {};
  bool _hasMoreHistory = false;
  int? _nextHistoryFromMessageId;

  /// When true, [fetchLiveChatVideos] must keep using [SearchMessagesFilterDocument] for pagination anchors.
  bool _liveUsesDocumentFilter = false;
  bool _loadingMore = false;
  bool _initialLoading = true;
  String? _error;

  /// Incremented on thread/chat changes and before each load; stale async completions are ignored.
  int _loadGeneration = 0;

  /// Per-card UI: download progress, pause/resume, local file for play/delete.
  final Map<String, _MyTgItemUiState> _tgItemUi = <String, _MyTgItemUiState>{};

  @override
  void initState() {
    super.initState();
    final cached = _TelegramChatMediaSessionCache.read(
      widget.tdlibChatId,
      widget.messageThreadId,
      widget.libraryIndexed,
    );
    if (cached != null) {
      _items.addAll(List<TelegramVideoMetadata>.from(cached.videos));
      _thumbnailCache.addAll(Map<String, String?>.from(cached.thumbnails));
      _hasMoreHistory = cached.hasMoreHistory;
      _nextHistoryFromMessageId = cached.nextHistoryFromMessageId;
      _liveUsesDocumentFilter = cached.liveUsesDocumentFilter;
      _initialLoading = false;
      return;
    }
    _loadInitial();
  }

  @override
  void didUpdateWidget(MyTelegramChatMediaScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageThreadId != widget.messageThreadId ||
        oldWidget.tdlibChatId != widget.tdlibChatId ||
        oldWidget.libraryIndexed != widget.libraryIndexed) {
      _resetStateForThreadOrChatChange();
    }
  }

  void _resetStateForThreadOrChatChange() {
    _loadInitial();
  }

  @override
  void dispose() {
    _persistToSessionCache();
    super.dispose();
  }

  void _persistToSessionCache() {
    _TelegramChatMediaSessionCache.put(
      tdlibChatId: widget.tdlibChatId,
      messageThreadId: widget.messageThreadId,
      libraryIndexed: widget.libraryIndexed,
      liveUsesDocumentFilter: _liveUsesDocumentFilter,
      videos: _items,
      thumbnails: _thumbnailCache,
      hasMoreHistory: _hasMoreHistory,
      nextHistoryFromMessageId: _nextHistoryFromMessageId,
    );
  }

  String _thumbCacheKey(OxChatMediaRow row) => '${row.chatId}_${row.fileId}_${row.messageId}';

  /// Disk cache file name in [DataRepository.fetchVideoThumbnail] — must be unique per **message**, not per file id.
  String _thumbnailDiskCacheKey(OxChatMediaRow row) {
    final cid = row.chatId;
    if (cid != null) {
      return 'tgchat_${cid}_${row.messageId}';
    }
    return 'tg_${row.fileId}_${row.messageId}';
  }

  List<OxChatMediaRow> _dedupeRowsByMessageId(List<OxChatMediaRow> rows) {
    final seen = <String>{};
    return rows.where((r) => seen.add(r.messageId)).toList();
  }

  /// Indexed API: per forum topic when [libraryIndexed] + [embedInTabView]; otherwise all indexed files for the chat.
  int? get _indexedMessageThreadQuery {
    if (!widget.libraryIndexed) return null;
    return widget.embedInTabView ? widget.messageThreadId : null;
  }

  Future<void> _loadInitial() async {
    final gen = ++_loadGeneration;
    // Instant empty grid when switching chat/topic (no PagingController — list is the page state).
    if (mounted) {
      setState(() {
        _items.clear();
        _thumbnailCache.clear();
        _tgItemUi.clear();
        _hasMoreHistory = false;
        _nextHistoryFromMessageId = null;
        _liveUsesDocumentFilter = false;
        _loadingMore = false;
        _error = null;
        _initialLoading = true;
      });
    } else {
      _items.clear();
      _thumbnailCache.clear();
      _tgItemUi.clear();
      _hasMoreHistory = false;
      _nextHistoryFromMessageId = null;
      _liveUsesDocumentFilter = false;
      _loadingMore = false;
    }

    try {
      final repo = await DataRepository.create();
      if (!mounted || gen != _loadGeneration) return;

      if (widget.libraryIndexed) {
        final page = await repo.fetchIndexedChatMedia(
          tdlibChatId: widget.tdlibChatId,
          messageThreadId: _indexedMessageThreadQuery,
          limit: _pageSize,
          offset: 0,
        );
        if (!mounted || gen != _loadGeneration) return;

        if (mounted) {
          final uniqueRows = _dedupeRowsByMessageId(page.items);
          setState(() {
            _initialLoading = false;
            _items.clear();
            _items.addAll(uniqueRows.map((row) => TelegramVideoMetadata(row, '')));
            _hasMoreHistory = page.hasMoreHistory;
            _nextHistoryFromMessageId = null;
          });
          unawaited(_resolveThumbnailsForRows(uniqueRows));
        }
        _persistToSessionCache();
        return;
      }

      final page = await repo.fetchLiveChatVideos(
        tdlibChatId: widget.tdlibChatId,
        messageThreadId: widget.messageThreadId,
      );
      if (!mounted || gen != _loadGeneration) return;

      if (mounted) {
        final uniqueRows = _dedupeRowsByMessageId(page.items);
        setState(() {
          _initialLoading = false;
          _items.clear();
          _items.addAll(uniqueRows.map((row) => TelegramVideoMetadata(row, '')));
          _hasMoreHistory = page.hasMoreHistory;
          _nextHistoryFromMessageId = page.nextHistoryFromMessageId;
          _liveUsesDocumentFilter = page.liveSearchUsesDocumentFilter;
        });
        unawaited(_resolveThumbnailsForRows(uniqueRows));
      }
      _persistToSessionCache();
    } catch (e) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _initialLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMoreHistory) return;

    if (widget.libraryIndexed) {
      final gen = _loadGeneration;
      setState(() => _loadingMore = true);
      try {
        final repo = await DataRepository.create();
        if (!mounted || gen != _loadGeneration) return;
        final page = await repo.fetchIndexedChatMedia(
          tdlibChatId: widget.tdlibChatId,
          messageThreadId: _indexedMessageThreadQuery,
          limit: _pageSize,
          offset: _items.length,
        );
        if (!mounted || gen != _loadGeneration) return;

        if (mounted) {
          final existingIds = _items.map((e) => e.row.messageId).toSet();
          final newRows = page.items.where((r) => existingIds.add(r.messageId)).toList();
          setState(() {
            _items.addAll(newRows.map((row) => TelegramVideoMetadata(row, '')));
            _hasMoreHistory = page.hasMoreHistory;
          });
          unawaited(_resolveThumbnailsForRows(newRows));
        }
        _persistToSessionCache();
      } finally {
        if (mounted) {
          setState(() => _loadingMore = false);
        }
      }
      return;
    }

    if (_nextHistoryFromMessageId == null) return;

    final gen = _loadGeneration;
    setState(() => _loadingMore = true);

    try {
      final repo = await DataRepository.create();
      if (!mounted || gen != _loadGeneration) return;
      final page = await repo.fetchLiveChatVideos(
        tdlibChatId: widget.tdlibChatId,
        messageThreadId: widget.messageThreadId,
        continueFromMessageId: _nextHistoryFromMessageId,
        continueWithDocumentFilter: _liveUsesDocumentFilter,
      );
      if (!mounted || gen != _loadGeneration) return;

      if (mounted) {
        final existingIds = _items.map((e) => e.row.messageId).toSet();
        final newRows = page.items.where((r) => existingIds.add(r.messageId)).toList();
        setState(() {
          _items.addAll(newRows.map((row) => TelegramVideoMetadata(row, '')));
          _hasMoreHistory = page.hasMoreHistory;
          _nextHistoryFromMessageId = page.nextHistoryFromMessageId;
          _liveUsesDocumentFilter = page.liveSearchUsesDocumentFilter;
        });
        unawaited(_resolveThumbnailsForRows(newRows));
      }
      _persistToSessionCache();
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _resolveThumbnailsForRows(List<OxChatMediaRow> rows) async {
    if (rows.isEmpty) return;
    final gen = _loadGeneration;
    final repo = await DataRepository.create();
    const batchSize = 3;

    for (var i = 0; i < rows.length; i += batchSize) {
      if (!mounted || gen != _loadGeneration) return;
      final end = i + batchSize > rows.length ? rows.length : i + batchSize;
      final chunk = rows.sublist(i, end);
      for (final row in chunk) {
        final key = _thumbCacheKey(row);
        if (_thumbnailCache.containsKey(key)) continue;
        try {
          final thumbnail = await repo.fetchVideoThumbnail(
            mediaId: row.fileId,
            diskCacheKey: _thumbnailDiskCacheKey(row),
            fileUniqueId: row.remoteFileId,
            chatId: row.chatId,
            messageId: int.tryParse(row.messageId),
          );
          _thumbnailCache[key] = thumbnail;
        } catch (_) {
          _thumbnailCache[key] = null;
        }
      }

      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        for (final row in chunk) {
          final path = _thumbnailCache[_thumbCacheKey(row)] ?? '';
          final j = _items.indexWhere((e) => e.row.fileId == row.fileId && e.row.messageId == row.messageId);
          if (j >= 0) {
            _items[j] = TelegramVideoMetadata(row, path);
          }
        }
      });
      if (end < rows.length) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
    if (mounted && gen == _loadGeneration) {
      _persistToSessionCache();
    }
  }

  Map<String, List<TelegramVideoMetadata>> _groupItemsByMonth(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final fmt = DateFormat.yMMMM(locale);
    final sorted = List<TelegramVideoMetadata>.from(_items)
      ..sort((a, b) {
        final da = DateTime.tryParse(a.row.messageDate ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final db = DateTime.tryParse(b.row.messageDate ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return db.compareTo(da);
      });
    final map = <String, List<TelegramVideoMetadata>>{};
    for (final v in sorted) {
      final d = DateTime.tryParse(v.row.messageDate ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final key = fmt.format(d);
      map.putIfAbsent(key, () => []).add(v);
    }
    return map;
  }

  int _indexInItems(TelegramVideoMetadata v) {
    final i = _items.indexWhere((e) => e.row.messageId == v.row.messageId);
    return i >= 0 ? i : 0;
  }

  Future<void> _onTelegramVideoPrimaryTap(BuildContext context, TelegramVideoMetadata video) async {
    final cid = video.row.chatId;
    final mid = int.tryParse(video.row.messageId);
    if (cid == null || mid == null) {
      showSnackBar(context, t.myTelegram.telegramChatIdMissing, type: SnackBarType.error);
      return;
    }
    final ui = _tgItemUi.putIfAbsent(video.ratingKey, _MyTgItemUiState.new);
    if (ui.phase == _MyTgDlPhase.completed && (ui.localPath?.isNotEmpty ?? false)) {
      await navigateToInternalVideoPlayerForUrl(context, metadata: video, videoUrl: ui.localPath!);
      return;
    }
    if (ui.phase == _MyTgDlPhase.downloading) {
      return;
    }
    await _showTelegramVideoActionsSheet(context, video, cid, mid);
  }

  Future<void> _showTelegramVideoActionsSheet(
    BuildContext context,
    TelegramVideoMetadata video,
    int chatId,
    int messageId,
  ) async {
    final mt = t.myTelegram;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text(mt.videoActionIndex),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_forwardToMainBot(context, chatId, messageId));
                },
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text(mt.videoActionStream),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_streamTelegramVideo(context, video, chatId, messageId));
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(mt.videoActionDownload),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_startTelegramDownload(video, chatId, messageId));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _forwardToMainBot(BuildContext context, int chatId, int messageId) async {
    try {
      final repo = await DataRepository.create();
      await repo.forwardTelegramMessageToMainBot(fromChatId: chatId, messageId: messageId);
      if (context.mounted) {
        showSnackBar(context, t.myTelegram.forwardToProviderSent, type: SnackBarType.success);
      }
    } catch (e) {
      if (context.mounted) {
        showSnackBar(context, '${t.myTelegram.forwardToProviderFailed}: $e', type: SnackBarType.error);
      }
    }
  }

  Future<void> _streamTelegramVideo(
    BuildContext context,
    TelegramVideoMetadata video,
    int chatId,
    int messageId,
  ) async {
    final repo = await DataRepository.create();
    try {
      final uri = await repo.resolveTelegramChatMessageStreamUrlForPlayback(
        chatId: chatId,
        messageId: messageId,
      );
      if (!context.mounted) return;
      if (uri == null) {
        showSnackBar(context, t.myTelegram.streamFailed, type: SnackBarType.error);
        return;
      }
      await navigateToInternalVideoPlayerForUrl(
        context,
        metadata: video,
        videoUrl: uri.toString(),
      );
    } catch (e) {
      if (context.mounted) {
        showSnackBar(context, '${t.myTelegram.streamFailed}: $e', type: SnackBarType.error);
      }
    } finally {
      await repo.releaseOxMediaPlaybackSession(reason: 'my_telegram_chat_stream_closed');
    }
  }

  Future<void> _startTelegramDownload(TelegramVideoMetadata video, int chatId, int messageId) async {
    try {
      final repo = await DataRepository.create();
      final fileId = await repo.getTelegramPlayableFileIdForMessage(chatId: chatId, messageId: messageId);
      if (!mounted) return;
      if (fileId == null) {
        showSnackBar(context, t.myTelegram.downloadFailed, type: SnackBarType.error);
        return;
      }
      _tgItemUi.putIfAbsent(video.ratingKey, _MyTgItemUiState.new)
        ..fileId = fileId
        ..phase = _MyTgDlPhase.downloading
        ..cancelRequested = false
        ..progress = 0;
      setState(() {});
      unawaited(_runTelegramDownload(video, fileId));
    } catch (e) {
      if (mounted) {
        showSnackBar(context, '${t.myTelegram.downloadFailed}: $e', type: SnackBarType.error);
      }
    }
  }

  void _requestStopDownload(String ratingKey) {
    final ui = _tgItemUi[ratingKey];
    if (ui == null || ui.phase != _MyTgDlPhase.downloading) return;
    ui.cancelRequested = true;
    setState(() {});
  }

  Future<void> _runTelegramDownload(TelegramVideoMetadata video, int fileId) async {
    final rk = video.ratingKey;
    try {
      final repo = await DataRepository.create();
      final ui = _tgItemUi[rk];
      if (ui == null) return;
      final path = await repo.downloadTelegramFileToCompletion(
        fileId: fileId,
        startOffset: ui.resumeOffset,
        shouldCancel: () => _tgItemUi[rk]?.cancelRequested ?? false,
        onProgress: (downloaded, total) {
          if (!mounted) return;
          setState(() {
            final s = _tgItemUi[rk];
            if (s == null) return;
            s.progress = total > 0 ? downloaded / total : 0;
          });
        },
      );
      if (!mounted) return;
      final st = _tgItemUi[rk];
      if (st == null) return;
      if (path != null && path.isNotEmpty) {
        setState(() {
          st
            ..phase = _MyTgDlPhase.completed
            ..localPath = path
            ..cancelRequested = false;
        });
        return;
      }
      if (st.cancelRequested) {
        final prog = await repo.getTelegramFileProgress(fileId);
        setState(() {
          st.phase = _MyTgDlPhase.paused;
          st.cancelRequested = false;
          if (prog != null) {
            st.resumeOffset = prog.$1;
          }
        });
        return;
      }
      setState(() {
        st.phase = _MyTgDlPhase.idle;
      });
      showSnackBar(context, t.myTelegram.downloadFailed, type: SnackBarType.error);
    } catch (e) {
      if (mounted) {
        final st = _tgItemUi[rk];
        if (st != null) {
          setState(() => st.phase = _MyTgDlPhase.idle);
        }
        showSnackBar(context, '${t.myTelegram.downloadFailed}: $e', type: SnackBarType.error);
      }
    }
  }

  Future<void> _resumeTelegramDownload(TelegramVideoMetadata video) async {
    final ui = _tgItemUi[video.ratingKey];
    final fid = ui?.fileId;
    if (ui == null || fid == null) return;
    ui
      ..phase = _MyTgDlPhase.downloading
      ..cancelRequested = false;
    setState(() {});
    unawaited(_runTelegramDownload(video, fid));
  }

  Future<void> _playDownloadedFile(BuildContext context, TelegramVideoMetadata video) async {
    final path = _tgItemUi[video.ratingKey]?.localPath;
    if (path == null || path.isEmpty) return;
    await navigateToInternalVideoPlayerForUrl(context, metadata: video, videoUrl: path);
  }

  void _deleteTelegramDownload(TelegramVideoMetadata video) {
    final ui = _tgItemUi[video.ratingKey];
    final path = ui?.localPath;
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    setState(() {
      _tgItemUi.remove(video.ratingKey);
    });
  }

  Widget _telegramCardActionOverlay(TelegramVideoMetadata video, _MyTgItemUiState ui) {
    final mt = t.myTelegram;
    switch (ui.phase) {
      case _MyTgDlPhase.downloading:
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: (ui.progress > 0 && ui.progress <= 1) ? ui.progress : null,
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _requestStopDownload(video.ratingKey),
                    child: Text(mt.videoStopDownload, style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        );
      case _MyTgDlPhase.paused:
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => unawaited(_resumeTelegramDownload(video)),
                    child: Text(mt.videoResumeDownload, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    onPressed: () => _deleteTelegramDownload(video),
                    child: Text(mt.videoDeleteDownload, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ),
        );
      case _MyTgDlPhase.completed:
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => unawaited(_playDownloadedFile(context, video)),
                    child: Text(mt.videoPlay, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => _deleteTelegramDownload(video),
                    child: Text(mt.videoDeleteDownload, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ),
        );
      case _MyTgDlPhase.idle:
        return const SizedBox.shrink();
    }
  }

  Widget _buildVideoGalleryScroll() {
    return _GalleryGrid(
      tdlibChatId: widget.tdlibChatId,
      messageThreadId: widget.messageThreadId,
      libraryIndexed: widget.libraryIndexed,
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
        if (settings.viewMode == ViewMode.list) {
          return ListView.builder(
            padding: GridLayoutConstants.gridPadding,
            clipBehavior: Clip.none,
            itemCount: _items.length,
            itemBuilder: (c, i) => _buildVideoGridItem(_items[i], i),
          );
        }
        final grouped = _groupItemsByMonth(context);
        return CustomScrollView(
          clipBehavior: Clip.none,
          slivers: [
            for (final e in grouped.entries) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                  child: Text(
                    e.key,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: tokens(context).textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: GridLayoutConstants.gridPadding,
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final maxExt = GridSizeCalculator.getMaxCrossAxisExtent(context, settings.libraryDensity);
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: maxExt,
                        childAspectRatio: GridLayoutConstants.posterAspectRatio,
                        crossAxisSpacing: GridLayoutConstants.crossAxisSpacing,
                        mainAxisSpacing: GridLayoutConstants.mainAxisSpacing,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (c, i) => _buildVideoGridItem(e.value[i], _indexInItems(e.value[i])),
                        childCount: e.value.length,
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
      ),
    );
  }

  Widget _buildVideoGridItem(TelegramVideoMetadata video, int index) {
    final cap = video.row.caption?.trim();
    final ui = _tgItemUi[video.ratingKey];
    Widget card = FocusableMediaCard(
      key: Key(video.ratingKey),
      item: video,
      isOffline: true,
      onPrimaryAction: (ctx) => _onTelegramVideoPrimaryTap(ctx, video),
    );
    if (cap != null) {
      final showCaptionHint = cap.contains(RegExp(r'[\r\n]')) || cap.length > 72;
      if (showCaptionHint) {
        card = Tooltip(
          padding: const EdgeInsets.all(12),
          message: cap,
          waitDuration: const Duration(milliseconds: 350),
          child: card,
        );
      }
    }
    final overlayState = ui;
    final showOverlay = overlayState != null &&
        (overlayState.phase == _MyTgDlPhase.downloading ||
            overlayState.phase == _MyTgDlPhase.paused ||
            (overlayState.phase == _MyTgDlPhase.completed &&
                (overlayState.localPath?.isNotEmpty ?? false)));
    if (!showOverlay) {
      return card;
    }
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        card,
        Positioned(
          left: 4,
          right: 4,
          bottom: 4,
          child: _telegramCardActionOverlay(video, overlayState),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mt = t.myTelegram;

    if (widget.embedInTabView) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  IconButton(
                    tooltip: t.common.refresh,
                    onPressed: _initialLoading ? null : _loadInitial,
                    icon: _initialLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const AppIcon(Symbols.refresh_rounded, fill: 1),
                  ),
                  if (_items.isNotEmpty)
                    Expanded(
                      child: Text(
                        '${_items.length} videos',
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens(context).textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: _buildBody(mt)),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.chatTitle} - ${mt.mediaTitle}'),
        actions: [
          IconButton(
            tooltip: t.common.refresh,
            onPressed: _initialLoading ? null : _loadInitial,
            icon: _initialLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const AppIcon(Symbols.refresh_rounded, fill: 1),
          ),
          if (_items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_items.length} videos',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted, fontWeight: FontWeight.w500),
                ),
              ),
            ),
        ],
      ),
      body: _buildBody(mt),
    );
  }

  Widget _buildBody(dynamic telegramStrings) {
    // Show initial loading state
    if (_initialLoading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // Show error state
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(Symbols.error_rounded, fill: 1, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(telegramStrings.mediaLoadError),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadInitial,
                icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
                label: Text(t.common.retry),
              ),
            ],
          ),
        ),
      );
    }

    // Show empty state
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(Symbols.video_file_rounded, fill: 1, size: 48, color: tokens(context).textMuted),
              const SizedBox(height: 16),
              Text(
                widget.libraryIndexed ? telegramStrings.mediaEmpty : telegramStrings.tdlibChatMediaEmpty,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Show video grid (month groups like Telegram) with load more
    return Column(
      children: [
        Expanded(
          child: _buildVideoGalleryScroll(),
        ),

        // Load more (older history), or sync hint when TDLib may still be filling history, or end-of-list.
        if (_hasMoreHistory)
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: _loadingMore ? null : _loadMore,
              icon: _loadingMore
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const AppIcon(Symbols.expand_more_rounded, fill: 1),
              label: Text(_loadingMore ? 'Loading...' : telegramStrings.loadMoreMedia),
              style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
            ),
          )
        else if (!widget.libraryIndexed && _items.length < _pageSize)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  telegramStrings.mediaSyncMayLoadMore,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _initialLoading ? null : _loadInitial,
                  icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
                  label: Text(telegramStrings.checkForMoreVideos),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Text(
              telegramStrings.mediaEndOfList,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted, fontWeight: FontWeight.w500),
            ),
          ),
      ],
    );
  }
}
