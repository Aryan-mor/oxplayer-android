import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/debug/app_debug_log.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tv_button.dart';
import '../../data/models/app_media.dart';
import '../../providers.dart';
import '../../telegram/tdlib_facade.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const int _gridColumns = 5;
  static const double _gridRowExtent = 390;

  bool _isSyncing = false;
  DateTime? _lastSyncTime;
  final ScrollController _gridScrollController = ScrollController();
  final ScrollController _sidebarScrollController = ScrollController();
  final FocusScopeNode _sidebarScopeNode =
      FocusScopeNode(debugLabel: 'HomeSidebarScope');
  final FocusScopeNode _contentScopeNode =
      FocusScopeNode(debugLabel: 'HomeContentScope');

  late final List<FocusNode> _typeFocusNodes;
  final List<FocusNode> _sourceFocusNodes = <FocusNode>[];
  final List<FocusNode> _gridFocusNodes = <FocusNode>[];
  late final FocusNode _syncButtonFocusNode;
  late final FocusNode _logoutButtonFocusNode;

  @override
  void initState() {
    super.initState();
    _typeFocusNodes = List.generate(
      3,
      (index) => FocusNode(debugLabel: 'TypeFocus$index'),
    );
    _syncButtonFocusNode = FocusNode(debugLabel: 'SyncButtonFocus');
    _logoutButtonFocusNode = FocusNode(debugLabel: 'LogoutButtonFocus');

    AppDebugLog.instance.log('HomeScreen: initState');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAutoSync();
    });
  }

  @override
  void dispose() {
    _gridScrollController.dispose();
    _sidebarScrollController.dispose();
    for (final node in _typeFocusNodes) {
      node.dispose();
    }
    for (final node in _sourceFocusNodes) {
      node.dispose();
    }
    for (final node in _gridFocusNodes) {
      node.dispose();
    }
    _syncButtonFocusNode.dispose();
    _logoutButtonFocusNode.dispose();
    _sidebarScopeNode.dispose();
    _contentScopeNode.dispose();
    super.dispose();
  }

  Future<void> _checkAutoSync() async {
    final auth = ref.read(authNotifierProvider);
    if (auth.apiAccessToken != null && auth.apiAccessToken!.isNotEmpty) {
      try {
        final currentLibrary = await ref.read(mediaListProvider.future);
        AppDebugLog.instance.log('HomeScreen: Initial library fetch returned ${currentLibrary.length} items');

        if (_lastSyncTime == null) {
          if (currentLibrary.isEmpty) {
              AppDebugLog.instance.log('HomeScreen: Library is empty, auto-triggering Telegram sync');
              await _triggerSync(isManual: false);
          } else {
              AppDebugLog.instance.log('HomeScreen: Library is not empty, skipping auto Telegram sync');
              if (mounted) setState(() => _lastSyncTime = DateTime.now());
          }
        }
      } catch (e) {
        AppDebugLog.instance.log('HomeScreen: Failed to fetch initial library provider: $e');
      }
    }
  }

  Future<String> _requireApiAccessToken() async {
    final auth = ref.read(authNotifierProvider);
    final existing = auth.apiAccessToken;
    if (existing != null && existing.isNotEmpty) {
      AppDebugLog.instance.log(
        'HomeScreen: reusing API token (len=${existing.length})',
      );
      return existing;
    }

    final config = ref.read(appConfigProvider);
    if (!config.hasApiConfig) {
      throw StateError(
        'TV_APP_API_BASE_URL and one of TV_APP_WEBAPP_SHORT_NAME / TV_APP_WEBAPP_URL must be set in assets/env/default.env',
      );
    }

    final tdlib = ref.read(tdlibFacadeProvider);
    final api = ref.read(tvAppApiServiceProvider);
    AppDebugLog.instance.log('HomeScreen: requesting fresh API access token');
    final accessToken =
        await api.authenticateWithTelegram(tdlib: tdlib, config: config);
    await auth.setApiAccessToken(accessToken);
    AppDebugLog.instance.log(
      'HomeScreen: API token saved (len=${accessToken.length})',
    );
    return accessToken;
  }

  bool _isUnauthorized(DioException e) {
    final status = e.response?.statusCode;
    return status == 401 || status == 403;
  }

  Future<void> _runSyncWithToken(String accessToken) async {
    final api = ref.read(tvAppApiServiceProvider);
    final config = ref.read(appConfigProvider);
    final tdlib = ref.read(tdlibFacadeProvider);

    // 1. Fetch current library from server
    final currentLibrary = await api.fetchLibrary(
      config: config,
      accessToken: accessToken,
    );

    // 2. Extract existing IDs to compute the set difference
    final existingFileIds = currentLibrary
        .expand((agg) => agg.files)
        .map((f) => f.id)
        .toSet();

    AppDebugLog.instance.log(
      'HomeScreen: Found ${existingFileIds.length} existing files from server',
    );

    // 3. Search Telegram for all files
    AppDebugLog.instance.log('HomeScreen: Scanning Telegram for file IDs...');
    await api.collectMediaFileIdsFromTelegram(
      tdlib: tdlib,
      config: config,
      onBatch: (discoveredIds) async {
        // 4. Calculate new IDs in this batch
        final newMediaFileIds = discoveredIds.difference(existingFileIds);

        // 5. Send new files to server if any
        if (newMediaFileIds.isNotEmpty) {
          AppDebugLog.instance.log(
            'HomeScreen: Found ${newMediaFileIds.length} new files to sync (Out of ${discoveredIds.length} batch collected)',
          );
          await api.syncLibrary(
            config: config,
            accessToken: accessToken,
            mediaFileIds: newMediaFileIds.toList(),
          );

          // Register them so we avoid re-syncing if Telegram repeats a file
          existingFileIds.addAll(newMediaFileIds);

          // 6. Refresh UI state with latest library while still syncing
          ref.invalidate(mediaListProvider);
        } else {
          AppDebugLog.instance.log('HomeScreen: No new files found in this batch');
        }
      },
    );
  }

  Future<void> _triggerSync({bool isManual = true}) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    AppDebugLog.instance.log('HomeScreen: Sync started (isManual=$isManual)');

    try {
      var accessToken = await _requireApiAccessToken();
      try {
        await _runSyncWithToken(accessToken);
      } on DioException catch (e) {
        if (!_isUnauthorized(e)) rethrow;

        AppDebugLog.instance.log(
          'HomeScreen: API token rejected (status=${e.response?.statusCode}), refreshing once',
        );
        final auth = ref.read(authNotifierProvider);
        await auth.clearApiAccessToken();
        try {
          accessToken = await _requireApiAccessToken();
          await _runSyncWithToken(accessToken);
        } catch (refreshError) {
          AppDebugLog.instance.log(
            'HomeScreen: token refresh/retry failed, logging out: $refreshError',
          );
          await auth.clearSession();
          rethrow;
        }
      }

      if (mounted) setState(() => _lastSyncTime = DateTime.now());
      AppDebugLog.instance.log('HomeScreen: Sync completed successfully');
    } catch (e) {
      AppDebugLog.instance.log('HomeScreen: Sync failed: $e');
      if (e is DioException) {
        AppDebugLog.instance.log(
          'HomeScreen: DioException details '
          'type=${e.type} status=${e.response?.statusCode} '
          'uri=${e.requestOptions.uri} '
          'response=${e.response?.data}',
        );
      }
      if (mounted) {
        final message = switch (e) {
          TdlibInteractiveLoginRequired _ => e.toString(),
          DioException _ =>
            'Sync failed: HTTP ${e.response?.statusCode ?? '-'} ${e.requestOptions.path}\n${e.message}',
          _ => 'Sync failed: $e',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
      AppDebugLog.instance.log('HomeScreen: Sync finished (_isSyncing=false)');
    }
  }

  bool _isRight(KeyEvent event) =>
      event is KeyDownEvent &&
      event.logicalKey == LogicalKeyboardKey.arrowRight;
  bool _isLeft(KeyEvent event) =>
      event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowLeft;

  void _resizeFocusNodeList(
      List<FocusNode> nodes, int targetLength, String prefix) {
    while (nodes.length < targetLength) {
      nodes.add(FocusNode(debugLabel: '$prefix${nodes.length}'));
    }
    while (nodes.length > targetLength) {
      nodes.removeLast().dispose();
    }
  }

  void _syncDynamicFocusNodes({
    required int sourceCount,
    required int gridCount,
  }) {
    _resizeFocusNodeList(_sourceFocusNodes, sourceCount, 'SourceFocus');
    _resizeFocusNodeList(_gridFocusNodes, gridCount, 'GridFocus');
  }

  void _focusGridFromSidebar() {
    if (_gridFocusNodes.isEmpty) return;
    final stored = ref.read(lastFocusedGridIndexProvider);
    final index = stored.clamp(0, _gridFocusNodes.length - 1);
    _contentScopeNode.requestFocus(_gridFocusNodes[index]);
  }

  void _focusActiveSidebarNode({
    required LibraryTypeFilter typeFilter,
    required String? sourceFilter,
    required List<SourceFilterOption> sources,
  }) {
    if (sourceFilter != null) {
      final sourceIndex = sources.indexWhere((s) => s.id == sourceFilter);
      if (sourceIndex >= 0 && sourceIndex < _sourceFocusNodes.length) {
        _sidebarScopeNode.requestFocus(_sourceFocusNodes[sourceIndex]);
        return;
      }
    }
    final typeIndex = switch (typeFilter) {
      LibraryTypeFilter.all => 0,
      LibraryTypeFilter.movies => 1,
      LibraryTypeFilter.series => 2,
    };
    _sidebarScopeNode.requestFocus(_typeFocusNodes[typeIndex]);
  }

  void _scrollToFocusedIndex(int index) {
    if (!_gridScrollController.hasClients) return;
    final row = index ~/ _gridColumns;
    final viewport = _gridScrollController.position.viewportDimension;
    final target =
        row * _gridRowExtent - ((viewport - _gridRowExtent) / 2).clamp(0, 600);
    final min = _gridScrollController.position.minScrollExtent;
    final max = _gridScrollController.position.maxScrollExtent;
    final clamped = target.clamp(min, max).toDouble();
    if ((_gridScrollController.offset - clamped).abs() < 10) return;
    unawaited(
      _gridScrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
      ),
    );
  }

  void _scrollSidebarToSourceIndex(int index) {
    if (!_sidebarScrollController.hasClients) return;
    const itemExtent = 56.0;
    const gap = 8.0;
    const edgePadding = 12.0;
    final rowTop = index * (itemExtent + gap);
    final rowBottom = rowTop + itemExtent;
    final viewportStart = _sidebarScrollController.offset;
    final viewportEnd =
        viewportStart + _sidebarScrollController.position.viewportDimension;

    double? targetOffset;
    if (rowTop < viewportStart + edgePadding) {
      targetOffset = (rowTop - edgePadding)
          .clamp(
            _sidebarScrollController.position.minScrollExtent,
            _sidebarScrollController.position.maxScrollExtent,
          )
          .toDouble();
    } else if (rowBottom > viewportEnd - edgePadding) {
      targetOffset = (rowBottom - _sidebarScrollController.position.viewportDimension + edgePadding)
          .clamp(
            _sidebarScrollController.position.minScrollExtent,
            _sidebarScrollController.position.maxScrollExtent,
          )
          .toDouble();
    }

    if (targetOffset == null) return;
    unawaited(
      _sidebarScrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeInOut,
      ),
    );
  }

  String _formatLastSync() {
    if (_lastSyncTime == null) return 'Never';
    final diff = DateTime.now().difference(_lastSyncTime!);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void _openItem(BuildContext context, AppMediaAggregate item) {
    final id = item.media.id.trim().isNotEmpty
        ? item.media.id.trim()
        : (item.files.isNotEmpty ? item.files.first.mediaId.trim() : '');
    if (id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open item: missing id.')),
      );
      return;
    }
    context.push('/item/${Uri.encodeComponent(id)}');
  }

  @override
  Widget build(BuildContext context) {
    final mediaAsync = ref.watch(mediaListProvider);
    if (mediaAsync.hasError) {
      return Scaffold(
        body: Center(child: Text('Library error: ${mediaAsync.error}')),
      );
    }
    if (!mediaAsync.hasValue) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final sources = ref.watch(sourceFilterOptionsProvider);
    final selectedType = ref.watch(selectedTypeFilterProvider);
    final selectedSource = ref.watch(selectedSourceFilterProvider);
    if (selectedSource != null && !sources.any((s) => s.id == selectedSource)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedSourceFilterProvider.notifier).state = null;
      });
    }
    final filtered = ref.watch(filteredMediaProvider);
    _syncDynamicFocusNodes(
      sourceCount: sources.length,
      gridCount: filtered.length,
    );

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 360,
            decoration: const BoxDecoration(
              color: AppColors.card,
              border: Border(right: BorderSide(color: AppColors.border)),
            ),
            padding: const EdgeInsets.all(20),
            child: FocusScope(
              node: _sidebarScopeNode,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TeleCima',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _isSyncing
                        ? 'Sync in progress...'
                        : 'Last sync: ${_formatLastSync()}',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 18),
                  TVButton(
                    focusNode: _syncButtonFocusNode,
                    autofocus: true,
                    onKeyEvent: (_, event) {
                      if (_isRight(event)) {
                        _focusGridFromSidebar();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    onPressed: _isSyncing ? null : () => _triggerSync(isManual: true),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sync, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(_isSyncing ? 'Syncing...' : 'Sync Now'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Browse by Type',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < 3; i++) ...[
                    _SidebarFilterButton(
                      focusNode: _typeFocusNodes[i],
                      label: switch (i) {
                        0 => 'All',
                        1 => 'Movies',
                        _ => 'Series',
                      },
                      selected: selectedType ==
                          switch (i) {
                            0 => LibraryTypeFilter.all,
                            1 => LibraryTypeFilter.movies,
                            _ => LibraryTypeFilter.series,
                          },
                      onKeyEvent: (_, event) {
                        if (_isRight(event)) {
                          _focusGridFromSidebar();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      onPressed: () {
                        ref.read(selectedTypeFilterProvider.notifier).state =
                            switch (i) {
                          0 => LibraryTypeFilter.all,
                          1 => LibraryTypeFilter.movies,
                          _ => LibraryTypeFilter.series,
                        };
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 8),
                  const Text(
                    'Sources',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.separated(
                      controller: _sidebarScrollController,
                      itemCount: sources.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final source = sources[index];
                        final isSelected = selectedSource == source.id;
                        return _SidebarFilterButton(
                          focusNode: _sourceFocusNodes[index],
                          label: source.label,
                          selected: isSelected,
                          onKeyEvent: (_, event) {
                            if (_isRight(event)) {
                              _focusGridFromSidebar();
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          onPressed: () {
                            ref
                                .read(selectedSourceFilterProvider.notifier)
                                .state = isSelected ? null : source.id;
                          },
                          onFocusChanged: (focused) {
                            if (!focused) return;
                            _scrollSidebarToSourceIndex(index);
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  TVButton(
                    focusNode: _logoutButtonFocusNode,
                    onKeyEvent: (_, event) {
                      if (_isRight(event)) {
                        _focusGridFromSidebar();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    onPressed: () async {
                      await ref.read(authNotifierProvider).clearSession();
                      if (!context.mounted) return;
                      context.go('/welcome');
                    },
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.logout, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Logout'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: FocusScope(
              node: _contentScopeNode,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Library',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${filtered.length} items',
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text(
                                'No titles match this filter.',
                                style: TextStyle(color: AppColors.textMuted),
                              ),
                            )
                          : GridView.builder(
                              controller: _gridScrollController,
                              cacheExtent: 1800,
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: _gridColumns,
                                childAspectRatio: 0.66,
                                crossAxisSpacing: 14,
                                mainAxisSpacing: 14,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final item = filtered[index];
                                return _PosterGridTile(
                                  item: item,
                                  focusNode: _gridFocusNodes[index],
                                  autofocus: index ==
                                      ref.watch(lastFocusedGridIndexProvider),
                                  onFocusChanged: (focused) {
                                    if (!focused) return;
                                    ref
                                        .read(lastFocusedGridIndexProvider
                                            .notifier)
                                        .state = index;
                                    _scrollToFocusedIndex(index);
                                  },
                                  onKeyEvent: (_, event) {
                                    if (_isLeft(event) &&
                                        index % _gridColumns == 0) {
                                      _focusActiveSidebarNode(
                                        typeFilter: selectedType,
                                        sourceFilter: selectedSource,
                                        sources: sources,
                                      );
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  onOpen: () => _openItem(context, item),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarFilterButton extends StatelessWidget {
  const _SidebarFilterButton({
    required this.focusNode,
    required this.label,
    required this.selected,
    required this.onPressed,
    required this.onKeyEvent,
    this.onFocusChanged,
  });

  final FocusNode focusNode;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKeyEvent;
  final ValueChanged<bool>? onFocusChanged;

  @override
  Widget build(BuildContext context) {
    return TVButton(
      focusNode: focusNode,
      onFocusChanged: onFocusChanged,
      onKeyEvent: onKeyEvent,
      onPressed: onPressed,
      child: Row(
        children: [
          if (selected)
            const Icon(Icons.chevron_right, color: AppColors.highlight),
          if (selected) const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? AppColors.highlight : Colors.white,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterGridTile extends StatelessWidget {
  const _PosterGridTile({
    required this.item,
    required this.focusNode,
    required this.autofocus,
    required this.onFocusChanged,
    required this.onKeyEvent,
    required this.onOpen,
  });

  final AppMediaAggregate item;
  final FocusNode focusNode;
  final bool autofocus;
  final ValueChanged<bool> onFocusChanged;
  final KeyEventResult Function(FocusNode node, KeyEvent event) onKeyEvent;
  final VoidCallback onOpen;

  String? _resolvePosterUrl(String? posterPath) {
    final value = (posterPath ?? '').trim();
    if (value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('/')) return 'https://image.tmdb.org/t/p/w500$value';
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final poster = _resolvePosterUrl(item.media.posterPath) ?? '';
    return TVButton(
      focusNode: focusNode,
      autofocus: autofocus,
      onFocusChanged: onFocusChanged,
      onKeyEvent: onKeyEvent,
      onPressed: onOpen,
      padding: const EdgeInsets.all(0),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: poster.isEmpty
                  ? Container(
                      color: Colors.black26,
                      alignment: Alignment.center,
                      child: const Icon(Icons.movie, size: 42),
                    )
                  : CachedNetworkImage(
                      imageUrl: poster,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          const Center(child: CircularProgressIndicator()),
                      errorWidget: (_, __, ___) =>
                          const Center(child: Icon(Icons.broken_image)),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                item.media.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
