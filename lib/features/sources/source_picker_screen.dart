import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/focus/section_focus_coordinator.dart';
import '../../core/layout/section_container.dart';
import '../../core/sources/sources_local_cache.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/oxplayer_button.dart';
import '../../providers.dart';
import '../../telegram/source_chats_tdlib.dart';

class SourcePickerScreen extends ConsumerStatefulWidget {
  const SourcePickerScreen({super.key});

  @override
  ConsumerState<SourcePickerScreen> createState() => _SourcePickerScreenState();
}

class _SourcePickerScreenState extends ConsumerState<SourcePickerScreen> {
  static const int _cols = 5;

  SourceChatPickerBucket _bucket = SourceChatPickerBucket.chats;
  final Map<int, TdlibPickerChatRow> _rowsByChatId = {};
  int _listLimit = 50;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int? _selfUserId;
  final Set<String> _indexedTelegramIds = {};

  final List<FocusNode> _focusNodes = <FocusNode>[];
  int? _focusedIndex;
  Timer? _debounce;
  final Map<int, bool> _pendingIndexed = {};
  final SectionFocusCoordinator _sectionFocusCoordinator =
      SectionFocusCoordinator();

  List<TdlibPickerChatRow> get _visibleRows {
    final list = _rowsByChatId.values.where((r) => r.matchesBucket(_bucket)).toList();
    if (_bucket == SourceChatPickerBucket.chats) {
      list.sort((a, b) {
        if (a.isSavedMessages != b.isSavedMessages) {
          return a.isSavedMessages ? -1 : 1;
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    } else {
      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return list;
  }

  @override
  void dispose() {
    _sectionFocusCoordinator.dispose();
    _debounce?.cancel();
    if (_pendingIndexed.isNotEmpty) {
      unawaited(_flushPending());
    }
    for (final n in _focusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _syncFocus(int n) {
    while (_focusNodes.length < n) {
      _focusNodes.add(FocusNode(debugLabel: 'picker-${_focusNodes.length}'));
    }
    while (_focusNodes.length > n) {
      _focusNodes.removeLast().dispose();
    }
  }

  Future<void> _loadIndexedIds() async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return;
    final api = ref.read(oxplayerApiServiceProvider);
    final cfg = ref.read(appConfigProvider);
    const buckets = ['chats', 'groups', 'channels', 'bots'];
    final set = <String>{};
    for (final b in buckets) {
      try {
        final page = await api.fetchUserChats(
          config: cfg,
          accessToken: token,
          bucket: b,
          indexedOnly: true,
          limit: 500,
          offset: 0,
        );
        for (final r in page.items) {
          set.add(r.telegramChatId);
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _indexedTelegramIds
          ..clear()
          ..addAll(set);
      });
    }
  }

  Future<void> _loadChats({required bool reset}) async {
    final facade = ref.read(tdlibFacadeProvider);
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _listLimit = 50;
        _rowsByChatId.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      _selfUserId ??= await tdlibGetSelfUserId(facade);
      final self = _selfUserId!;
      if (reset) {
        await tdlibLoadChatsPage(facade, limit: 80);
      } else {
        await tdlibLoadChatsPage(facade, limit: 40);
        _listLimit += 40;
      }
      final ids = await tdlibGetMainChatIds(facade, _listLimit);
      final cache = SourcesLocalCache.instance;
      for (final id in ids) {
        if (_rowsByChatId.containsKey(id)) continue;
        final chat = await tdlibGetChat(facade, id);
        if (chat == null) continue;
        final path = await tdlibCacheChatPhotoIfNeeded(
          facade: facade,
          telegramChatId: id,
          photo: chat.photo,
          existingPath: cache.readAvatarPathIfExists,
          writeJpeg: cache.writeAvatarJpeg,
        );
        final row = await tdlibBuildPickerRow(
          facade: facade,
          chat: chat,
          selfUserId: self,
          localAvatarPath: path,
        );
        if (row != null) {
          _rowsByChatId[id] = row;
        }
      }
      await cache.saveChatOrderSnapshot(ids);
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = '$e';
        });
      }
    }
  }

  void _scheduleFlush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _flushPending);
  }

  Future<void> _flushPending() async {
    if (_pendingIndexed.isEmpty) return;
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return;
    final api = ref.read(oxplayerApiServiceProvider);
    final cfg = ref.read(appConfigProvider);
    final copy = Map<int, bool>.from(_pendingIndexed);
    _pendingIndexed.clear();

    try {
      for (final id in copy.keys) {
        final row = _rowsByChatId[id];
        if (row == null) continue;
        await api.upsertUserChat(
          config: cfg,
          accessToken: token,
          telegramChatId: id,
          title: row.title,
          chatType: row.apiChatType,
          photoUrl: null,
          peerIsBot: row.peerIsBot,
        );
      }
      final items = copy.entries
          .map(
            (e) => <String, dynamic>{
              'telegramChatId': e.key,
              'isIndexed': e.value,
            },
          )
          .toList();
      await api.patchUserChatsIndexed(
        config: cfg,
        accessToken: token,
        items: items,
      );
      ref.read(indexedChatsRefreshGenerationProvider.notifier).state++;
    } catch (_) {}
  }

  void _toggleRow(TdlibPickerChatRow row) {
    final idStr = row.chatId.toString();
    final isOn = !_indexedTelegramIds.contains(idStr);
    setState(() {
      if (isOn) {
        _indexedTelegramIds.add(idStr);
      } else {
        _indexedTelegramIds.remove(idStr);
      }
      _pendingIndexed[row.chatId] = isOn;
    });
    _scheduleFlush();
  }

  KeyEventResult _onKey(int index, List<TdlibPickerChatRow> rows, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final total = rows.length;
    final cols = _cols;
    final row = index ~/ cols;
    final col = index % cols;
    if (k == LogicalKeyboardKey.arrowLeft && col > 0) {
      _focusNodes[index - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight && col < cols - 1 && index + 1 < total) {
      _focusNodes[index + 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (row > 0) {
        _focusNodes[index - cols].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (index + cols < total) {
        _focusNodes[index + cols].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      _toggleRow(rows[index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadIndexedIds();
      await _loadChats(reset: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visibleRows;
    final n = rows.length;
    _syncFocus(n);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(_flushPending());
          ref.read(indexedChatsRefreshGenerationProvider.notifier).state++;
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Select sources'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionContainer(
            sectionId: 'source_picker_buckets',
            focusCoordinator: _sectionFocusCoordinator,
            padding: const EdgeInsets.fromLTRB(
              AppLayout.tvHorizontalInset,
              8,
              AppLayout.tvHorizontalInset,
              4,
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _BucketChip(
                    label: 'Chats',
                    selected: _bucket == SourceChatPickerBucket.chats,
                    onPressed: () =>
                        setState(() => _bucket = SourceChatPickerBucket.chats),
                  ),
                  const SizedBox(width: 8),
                  _BucketChip(
                    label: 'Groups',
                    selected: _bucket == SourceChatPickerBucket.groups,
                    onPressed: () =>
                        setState(() => _bucket = SourceChatPickerBucket.groups),
                  ),
                  const SizedBox(width: 8),
                  _BucketChip(
                    label: 'Channels',
                    selected: _bucket == SourceChatPickerBucket.channels,
                    onPressed: () =>
                        setState(() => _bucket = SourceChatPickerBucket.channels),
                  ),
                  const SizedBox(width: 8),
                  _BucketChip(
                    label: 'Bots',
                    selected: _bucket == SourceChatPickerBucket.bots,
                    onPressed: () =>
                        setState(() => _bucket = SourceChatPickerBucket.bots),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : n == 0
                    ? const Center(
                        child: Text(
                          'No chats in this category.',
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      )
                    : SectionContainer(
                        sectionId: 'source_picker_grid',
                        focusCoordinator: _sectionFocusCoordinator,
                        child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          AppLayout.tvHorizontalInset,
                          8,
                          AppLayout.tvHorizontalInset,
                          AppLayout.screenBottomInset,
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: _cols,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: n,
                        itemBuilder: (context, index) {
                          final r = rows[index];
                          final indexed =
                              _indexedTelegramIds.contains(r.chatId.toString());
                          final focused = _focusedIndex == index;
                          return Focus(
                            focusNode: _focusNodes[index],
                            onFocusChange: (f) {
                              setState(() => _focusedIndex = f ? index : null);
                            },
                            onKeyEvent: (_, ev) => _onKey(index, rows, ev),
                            child: Material(
                              color: AppColors.card,
                              elevation: focused ? 8 : 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: indexed
                                      ? Colors.greenAccent
                                      : AppColors.border,
                                  width: indexed ? 3 : 1,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => _toggleRow(r),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Column(
                                    children: [
                                      Expanded(
                                        child: CircleAvatar(
                                          radius: 36,
                                          backgroundColor: AppColors.border,
                                          backgroundImage: r.localAvatarPath != null
                                              ? FileImage(io.File(r.localAvatarPath!))
                                              : null,
                                          child: r.localAvatarPath == null
                                              ? Text(
                                                  r.title.isNotEmpty
                                                      ? r.title[0].toUpperCase()
                                                      : '?',
                                                  style: const TextStyle(
                                                    fontSize: 28,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        r.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontWeight: focused
                                              ? FontWeight.w700
                                              : FontWeight.w600,
                                          fontSize: focused ? 12 : 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                        ),
                      ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Center(
              child: OxplayerButton(
                onPressed: _loadingMore
                    ? null
                    : () => _loadChats(reset: false),
                child: Text(_loadingMore ? 'Loading…' : 'Load more'),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _BucketChip extends StatelessWidget {
  const _BucketChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OxplayerButton(
      selected: selected,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      borderRadius: 8,
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}
