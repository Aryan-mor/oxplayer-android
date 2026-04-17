import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
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
import '../../services/auth_debug_service.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/video_player_navigation.dart';
import 'my_telegram_video_detail_screen.dart';
import 'telegram_video_download_ui.dart';
import 'telegram_video_metadata.dart';

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
  }) {
    _byChatId[_key(tdlibChatId, messageThreadId, libraryIndexed)] = _TelegramChatMediaCacheEntry(
      videos: List<TelegramVideoMetadata>.from(videos),
      thumbnails: Map<String, String?>.from(thumbnails),
      hasMoreHistory: hasMoreHistory,
      nextHistoryFromMessageId: nextHistoryFromMessageId,
    );
  }
}

class _TelegramChatMediaCacheEntry {
  const _TelegramChatMediaCacheEntry({
    required this.videos,
    required this.thumbnails,
    required this.hasMoreHistory,
    required this.nextHistoryFromMessageId,
  });

  final List<TelegramVideoMetadata> videos;
  final Map<String, String?> thumbnails;
  final bool hasMoreHistory;
  final int? nextHistoryFromMessageId;
}

/// Telegram chat/topic media grid ([ListView] or [CustomScrollView]).
/// Lists TDLib video messages using the same [FocusableMediaCard] / [MediaCard] as home hubs.
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

class _MyTelegramChatMediaScreenState extends State<MyTelegramChatMediaScreen> {
  /// Live gallery: [searchChatMessages] batch size (jump-search may merge multiple attempts per load).
  static const int _pageSize = 30;

  final List<TelegramVideoMetadata> _items = [];
  final Map<String, String?> _thumbnailCache = {};
  bool _hasMoreHistory = false;
  int? _nextHistoryFromMessageId;

  bool _loadingMore = false;
  bool _streamAllStarting = false;
  bool _initialLoading = true;
  String? _error;

  /// Incremented on thread/chat changes and before each load; stale async completions are ignored.
  int _loadGeneration = 0;

  /// Per-card UI: download progress, pause/resume, local file for play/delete.
  final Map<String, TelegramVideoItemUiState> _tgItemUi = <String, TelegramVideoItemUiState>{};

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
      );
      if (!mounted || gen != _loadGeneration) return;

      if (mounted) {
        final existingIds = _items.map((e) => e.row.messageId).toSet();
        final newRows = page.items.where((r) => existingIds.add(r.messageId)).toList();
        setState(() {
          _items.addAll(newRows.map((row) => TelegramVideoMetadata(row, '')));
          _hasMoreHistory = page.hasMoreHistory;
          _nextHistoryFromMessageId = page.nextHistoryFromMessageId;
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
    final ui = _tgItemUi.putIfAbsent(video.ratingKey, TelegramVideoItemUiState.new);
    if (ui.phase == TelegramVideoDlPhase.completed && (ui.localPath?.isNotEmpty ?? false)) {
      await navigateToInternalVideoPlayerForUrl(context, metadata: video, videoUrl: ui.localPath!);
      return;
    }
    if (ui.phase == TelegramVideoDlPhase.downloading) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MyTelegramVideoDetailScreen(
          chatTitle: widget.chatTitle,
          video: video,
          chatId: cid,
          messageId: mid,
          itemUi: ui,
          onItemUiChanged: () {
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  Future<void> _onTelegramVideoLongPress(BuildContext context, TelegramVideoMetadata video) async {
    final cid = video.row.chatId;
    final mid = int.tryParse(video.row.messageId);
    if (cid == null || mid == null) {
      showSnackBar(context, t.myTelegram.telegramChatIdMissing, type: SnackBarType.error);
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
              if (!PlatformDetector.isTV())
                ListTile(
                  leading: const Icon(Icons.cast_rounded),
                  title: const Text('Cast to TV'),
                  onTap: () {
                    Navigator.pop(ctx);
                    unawaited(_castTelegramToTv(context, chatId, messageId));
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

  Future<void> _castTelegramToTv(BuildContext context, int chatId, int messageId) async {
    try {
      final repo = await DataRepository.create();
      await repo.postOxCastOfferTelegram(chatId: chatId, messageId: messageId);
      if (context.mounted) {
        showSnackBar(context, 'Sent to TV', type: SnackBarType.success);
      }
    } catch (e) {
      if (context.mounted) {
        showSnackBar(context, 'Cast failed: $e', type: SnackBarType.error);
      }
    }
  }

  Future<void> _streamAllInOrder() async {
    if (_items.isEmpty || _streamAllStarting) return;
    setState(() => _streamAllStarting = true);
    final repo = await DataRepository.create();
    try {
      final playlist = List<TelegramVideoMetadata>.from(_items);
      final first = playlist.first;
      final cid = first.row.chatId;
      final mid = int.tryParse(first.row.messageId);
      if (cid == null || mid == null) {
        playMediaDebugError(
          'Stream all: missing chatId or messageId for first item "${first.displayTitle}" (ratingKey=${first.ratingKey})',
        );
        if (mounted) {
          showSnackBar(context, t.myTelegram.telegramChatIdMissing, type: SnackBarType.error);
        }
        return;
      }
      final uri = await repo.resolveTelegramChatMessageStreamUrlForPlayback(
        chatId: cid,
        messageId: mid,
      );
      if (!mounted) return;
      if (uri == null) {
        playMediaDebugError(
          'Stream all: could not resolve stream URL for first video (chatId=$cid messageId=$mid "${first.displayTitle}")',
        );
        showSnackBar(context, t.myTelegram.streamFailed, type: SnackBarType.error);
        return;
      }
      await navigateToInternalVideoPlayerForUrl(
        context,
        metadata: first,
        videoUrl: uri.toString(),
        telegramStreamPlaylist: playlist.length > 1 ? playlist : null,
        telegramStreamPlaylistIndex: 0,
      );
    } catch (e, st) {
      playMediaDebugError('Stream all: failed before or during player open: $e\n$st');
      if (mounted) {
        showSnackBar(context, '${t.myTelegram.streamFailed}: $e', type: SnackBarType.error);
      }
    } finally {
      await repo.releaseOxMediaPlaybackSession(reason: 'my_telegram_stream_all_closed');
      if (mounted) {
        setState(() => _streamAllStarting = false);
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
        playMediaDebugError(
          'My Telegram single stream: resolveTelegramChatMessageStreamUrlForPlayback returned null '
          '(chatId=$chatId messageId=$messageId "${video.displayTitle}")',
        );
        showSnackBar(context, t.myTelegram.streamFailed, type: SnackBarType.error);
        return;
      }
      await navigateToInternalVideoPlayerForUrl(
        context,
        metadata: video,
        videoUrl: uri.toString(),
      );
    } catch (e, st) {
      playMediaDebugError(
        'My Telegram single stream: exception (chatId=$chatId messageId=$messageId "${video.displayTitle}"): $e\n$st',
      );
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
      _tgItemUi.putIfAbsent(video.ratingKey, TelegramVideoItemUiState.new)
        ..fileId = fileId
        ..phase = TelegramVideoDlPhase.downloading
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
    if (ui == null || ui.phase != TelegramVideoDlPhase.downloading) return;
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
            ..phase = TelegramVideoDlPhase.completed
            ..localPath = path
            ..cancelRequested = false;
        });
        return;
      }
      if (st.cancelRequested) {
        final prog = await repo.getTelegramFileProgress(fileId);
        setState(() {
          st.phase = TelegramVideoDlPhase.paused;
          st.cancelRequested = false;
          if (prog != null) {
            st.resumeOffset = prog.$1;
          }
        });
        return;
      }
      setState(() {
        st.phase = TelegramVideoDlPhase.idle;
      });
      showSnackBar(context, t.myTelegram.downloadFailed, type: SnackBarType.error);
    } catch (e) {
      if (mounted) {
        final st = _tgItemUi[rk];
        if (st != null) {
          setState(() => st.phase = TelegramVideoDlPhase.idle);
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
      ..phase = TelegramVideoDlPhase.downloading
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

  Widget _telegramCardActionOverlay(TelegramVideoMetadata video, TelegramVideoItemUiState ui) {
    return TelegramVideoDownloadControls(
      phase: ui.phase,
      progress: ui.progress,
      compact: true,
      onStopDownload: () => _requestStopDownload(video.ratingKey),
      onResumeDownload: () => unawaited(_resumeTelegramDownload(video)),
      onDeleteDownload: () => _deleteTelegramDownload(video),
      onPlayDownloaded: () => unawaited(_playDownloadedFile(context, video)),
    );
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
      onLongPressAction: (ctx) => _onTelegramVideoLongPress(ctx, video),
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
        (overlayState.phase == TelegramVideoDlPhase.downloading ||
            overlayState.phase == TelegramVideoDlPhase.paused ||
            (overlayState.phase == TelegramVideoDlPhase.completed &&
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: FilledButton.tonalIcon(
            onPressed: _initialLoading || _streamAllStarting || _items.isEmpty ? null : _streamAllInOrder,
            icon: _streamAllStarting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const AppIcon(Symbols.playlist_play_rounded, fill: 1),
            label: Text(t.myTelegram.streamAll),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              alignment: Alignment.center,
            ),
          ),
        ),
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
