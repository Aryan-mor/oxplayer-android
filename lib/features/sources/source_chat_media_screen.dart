import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/focus/section_focus_coordinator.dart';
import '../../core/layout/section_container.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/oxplayer_button.dart';
import '../../data/models/user_chat_dtos.dart';
import '../../providers.dart';
import '../../telegram/source_chat_history_indexer.dart';
import '../../widgets/library_media_poster.dart';
import '../../widgets/telegram_file_playback_actions.dart';
import 'source_chat_media_models.dart';

class SourceChatMediaScreen extends ConsumerStatefulWidget {
  const SourceChatMediaScreen({
    super.key,
    required this.telegramChatId,
    required this.chatTitle,
    this.lastIndexedMessageId,
  });

  final int telegramChatId;
  final String chatTitle;
  /// Server cursor for incremental TDLib → API ingest.
  final String? lastIndexedMessageId;

  @override
  ConsumerState<SourceChatMediaScreen> createState() =>
      _SourceChatMediaScreenState();
}

class _SourceChatMediaScreenState extends ConsumerState<SourceChatMediaScreen> {
  static const int _cols = 5;

  final List<FocusNode> _focusNodes = <FocusNode>[];
  int? _focusedIndex;
  int? _overlayIndex;
  final ScrollController _scroll = ScrollController();
  final SectionFocusCoordinator _sectionFocusCoordinator =
      SectionFocusCoordinator();

  List<SourceChatMediaRow> _items = const [];
  bool _loading = true;
  String? _error;
  int _offset = 0;
  bool _hasMore = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _load(reset: true);
      if (!mounted) return;
      await _syncIndexedHistory();
      if (mounted) await _load(reset: true);
    });
  }

  Future<void> _syncIndexedHistory() async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return;
    final facade = ref.read(tdlibFacadeProvider);
    final api = ref.read(oxplayerApiServiceProvider);
    final cfg = ref.read(appConfigProvider);
    final last = int.tryParse(widget.lastIndexedMessageId ?? '');
    try {
      await syncIndexedChatHistoryToApi(
        facade: facade,
        api: api,
        config: cfg,
        accessToken: token,
        tdChatId: widget.telegramChatId,
        telegramChatId: widget.telegramChatId,
        lastIndexedMessageId: last,
      );
      ref.read(indexedChatsRefreshGenerationProvider.notifier).state++;
    } catch (_) {}
  }

  @override
  void dispose() {
    _sectionFocusCoordinator.dispose();
    for (final n in _focusNodes) {
      n.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _syncNodes(int n) {
    while (_focusNodes.length < n) {
      _focusNodes.add(FocusNode(debugLabel: 'src-media-${_focusNodes.length}'));
    }
    while (_focusNodes.length > n) {
      _focusNodes.removeLast().dispose();
    }
  }

  Future<void> _load({required bool reset}) async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Not signed in';
      });
      return;
    }
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _offset = 0;
        _hasMore = true;
        _items = const [];
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final api = ref.read(oxplayerApiServiceProvider);
      final cfg = ref.read(appConfigProvider);
      final page = await api.fetchSourceChatMedia(
        config: cfg,
        accessToken: token,
        telegramChatId: widget.telegramChatId,
        limit: 40,
        offset: reset ? 0 : _offset,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _items = page.items;
        } else {
          _items = [..._items, ...page.items];
        }
        _offset = _items.length;
        _hasMore = page.items.length >= 40 && _items.length < page.total;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '$e';
      });
    }
  }

  void _closeOverlay() => setState(() => _overlayIndex = null);

  KeyEventResult _onGridKey(
    int index,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      setState(() => _overlayIndex = index);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _overlayIndex == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_overlayIndex != null) {
          _closeOverlay();
        } else {
          context.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.chatTitle),
        ),
        body: Stack(
          children: [
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
            else if (_items.isEmpty)
              const Center(
                child: Text(
                  'No indexed videos yet. Pull to refresh after syncing.',
                  style: TextStyle(color: AppColors.textMuted),
                  textAlign: TextAlign.center,
                ),
              )
            else
              _buildGrid(),
            if (_overlayIndex != null) _buildOverlay(_overlayIndex!),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final n = _items.length;
    _syncNodes(n);
    return Column(
      children: [
        Expanded(
          child: SectionContainer(
            sectionId: 'source_chat_media_grid',
            focusCoordinator: _sectionFocusCoordinator,
            child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(
              AppLayout.tvHorizontalInset,
              12,
              AppLayout.tvHorizontalInset,
              AppLayout.screenBottomInset,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _cols,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.62,
            ),
            itemCount: n,
            itemBuilder: (context, index) {
              final row = _items[index];
              final agg = sourceChatRowToAggregate(
                telegramChatId: '${widget.telegramChatId}',
                row: row,
              );
              final focused = _focusedIndex == index;
              return Focus(
                focusNode: _focusNodes[index],
                onFocusChange: (f) {
                  if (f) {
                    setState(() => _focusedIndex = index);
                  } else if (_focusedIndex == index) {
                    setState(() => _focusedIndex = null);
                  }
                },
                onKeyEvent: (_, e) => _onGridKey(index, e),
                child: Material(
                  color: AppColors.card,
                  elevation: focused ? 6 : 0,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => setState(() => _overlayIndex = index),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: LibraryMediaPoster(
                            media: agg.media,
                            files: agg.files,
                            placeholderIconSize: 32,
                            progressStrokeWidth: 2,
                          ),
                        ),
                        if (focused && (row.caption ?? '').trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                            child: Text(
                              row.caption!.trim(),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11, height: 1.2),
                            ),
                          )
                        else
                          const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
              );
            },
            ),
          ),
        ),
        if (_hasMore)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: OxplayerButton(
              onPressed: _loadingMore ? null : () => _load(reset: false),
              child: Text(_loadingMore ? 'Loading…' : 'Load more'),
            ),
          ),
      ],
    );
  }

  Widget _buildOverlay(int index) {
    final row = _items[index];
    final agg = sourceChatRowToAggregate(
      telegramChatId: '${widget.telegramChatId}',
      row: row,
    );
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeOverlay,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
          Center(
            child: Transform.scale(
              scale: 1.08,
              child: Material(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                elevation: 12,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.42,
                    maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.32,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LibraryMediaPoster(
                              media: agg.media,
                              files: agg.files,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        if ((row.caption ?? '').trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            row.caption!.trim(),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        TelegramFilePlaybackActions(
                          media: agg.media,
                          file: agg.files.first,
                          downloadGlobalId: agg.media.id,
                          downloadTitle: agg.media.title,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          alignment: WrapAlignment.center,
                          children: [
                            OxplayerButton(
                              onPressed: () {
                                _closeOverlay();
                                context.push(
                                  '/telegram-item',
                                  extra: agg,
                                );
                              },
                              child: const Text('Full details'),
                            ),
                            OxplayerButton(
                              onPressed: _closeOverlay,
                              child: const Text('Back'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

