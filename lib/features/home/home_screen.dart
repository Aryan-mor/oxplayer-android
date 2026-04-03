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
import '../../data/library_telegram_sync.dart';
import '../../data/models/app_media.dart';
import '../../providers.dart';
import '../../telegram/tdlib_facade.dart';

const _kBackExitWindow = Duration(seconds: 3);

void _homeLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);
void _homeSyncLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.sync);

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const int _gridColumns = 5;
  static const double _gridRowExtent = 390;
  bool _isSyncing = false;
  bool _syncCancelRequested = false;
  DateTime? _lastSyncTime;
  DateTime? _lastBackPress;
  bool _isExiting = false;
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
  late final FocusNode _exploreFocusNode;
  late final FocusNode _logoutButtonFocusNode;

  @override
  void initState() {
    super.initState();
    _typeFocusNodes = List.generate(
      3,
      (index) => FocusNode(debugLabel: 'TypeFocus$index'),
    );
    _syncButtonFocusNode = FocusNode(debugLabel: 'SyncButtonFocus');
    _exploreFocusNode = FocusNode(debugLabel: 'ExploreNav');
    _logoutButtonFocusNode = FocusNode(debugLabel: 'LogoutButtonFocus');

    _homeLog('HomeScreen: initState');
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
    _exploreFocusNode.dispose();
    _logoutButtonFocusNode.dispose();
    _sidebarScopeNode.dispose();
    _contentScopeNode.dispose();
    super.dispose();
  }

  /// Runs incremental Telegram discovery on home open; manual Sync uses a full hashtag scan (no minDate).
  Future<void> _checkAutoSync() async {
    final auth = ref.read(authNotifierProvider);
    if (auth.apiAccessToken == null || auth.apiAccessToken!.isEmpty) {
      _homeLog('HomeScreen: skip auto sync (no API token yet)');
      return;
    }
    _homeLog('HomeScreen: auto library sync on open (incremental)');
    await _triggerSync(isManual: false, notifyUserOnFailure: false);
  }

  Future<String> _requireApiAccessToken() async {
    final auth = ref.read(authNotifierProvider);
    final existing = auth.apiAccessToken;
    if (existing != null && existing.isNotEmpty) {
      _homeLog('HomeScreen: reusing API token (len=${existing.length})');
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
    _homeLog('HomeScreen: requesting fresh API access token');
    final authResult =
        await api.authenticateWithTelegram(tdlib: tdlib, config: config);
    await auth.setApiAccessToken(authResult.accessToken);
    await auth.syncPreferredSubtitleLanguageFromServer(
      authResult.preferredSubtitleLanguage,
    );
    await auth.syncUserTypeFromServer(authResult.userType);
    _homeLog(
      'HomeScreen: API token saved (len=${authResult.accessToken.length})',
    );
    return authResult.accessToken;
  }

  bool _isUnauthorized(DioException e) {
    final status = e.response?.statusCode;
    return status == 401 || status == 403;
  }

  Future<void> _runSyncWithToken(
    String accessToken, {
    required TelegramLibrarySyncMode mode,
  }) async {
    _homeSyncLog(
        'HomeScreen: running Telegram library sync (${mode.name})');
    await runTelegramLibrarySync(
      api: ref.read(tvAppApiServiceProvider),
      config: ref.read(appConfigProvider),
      tdlib: ref.read(tdlibFacadeProvider),
      accessToken: accessToken,
      invalidateLibrary: () => ref.invalidate(libraryFetchProvider),
      mode: mode,
      onSyncAbortRequested: () {
        if (_syncCancelRequested) throw const LibrarySyncCancelled();
      },
    );
  }

  Future<void> _triggerSync({
    bool isManual = true,
    bool notifyUserOnFailure = true,
  }) async {
    if (_isSyncing) return;
    _syncCancelRequested = false;
    final syncMode = isManual
        ? TelegramLibrarySyncMode.full
        : TelegramLibrarySyncMode.incremental;
    setState(() => _isSyncing = true);
    _homeSyncLog('HomeScreen: Sync started (isManual=$isManual)');

    try {
      var accessToken = await _requireApiAccessToken();
      try {
        await _runSyncWithToken(accessToken, mode: syncMode);
      } on DioException catch (e) {
        if (!_isUnauthorized(e)) rethrow;

        _homeSyncLog(
          'HomeScreen: API token rejected (status=${e.response?.statusCode}), refreshing once',
        );
        final auth = ref.read(authNotifierProvider);
        await auth.clearApiAccessToken();
        try {
          accessToken = await _requireApiAccessToken();
          await _runSyncWithToken(accessToken, mode: syncMode);
        } catch (refreshError) {
          _homeSyncLog(
            'HomeScreen: token refresh/retry failed, logging out: $refreshError',
          );
          await auth.clearSession();
          rethrow;
        }
      }

      if (mounted) setState(() => _lastSyncTime = DateTime.now());
      ref.read(exploreCatalogRefreshGenerationProvider.notifier).state++;
      _homeSyncLog('HomeScreen: Sync completed successfully');
    } on LibrarySyncCancelled catch (_) {
      _homeSyncLog('HomeScreen: Sync cancelled by user');
    } catch (e) {
      _homeSyncLog('HomeScreen: Sync failed: $e');
      if (e is DioException) {
        _homeSyncLog(
          'HomeScreen: DioException details '
          'type=${e.type} status=${e.response?.statusCode} '
          'uri=${e.requestOptions.uri} '
          'response=${e.response?.data}',
        );
      }
      if (mounted && notifyUserOnFailure) {
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
      _syncCancelRequested = false;
      if (mounted) setState(() => _isSyncing = false);
      _homeSyncLog('HomeScreen: Sync finished (_isSyncing=false)');
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

  /// Keeps the focused filter row on screen when the sidebar list is long (D-pad / TV).
  void _ensureSidebarNodeVisible(FocusNode node) {
    final ctx = node.context;
    if (ctx == null || !ctx.mounted) return;
    unawaited(
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeInOut,
        alignment: 0.18,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
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

  Future<void> _gracefulExit() async {
    if (_isExiting) return;
    setState(() => _isExiting = true);
    _homeLog('HomeScreen: graceful exit — shutting down TDLib');
    try {
      final facade = ref.read(tdlibFacadeProvider);
      await facade.dispose().timeout(
            const Duration(seconds: 4),
            onTimeout: () =>
                _homeLog('HomeScreen: TDLib dispose timeout, exiting anyway'),
          );
    } catch (e) {
      _homeLog('HomeScreen: TDLib dispose error on exit: $e');
    }
    _homeLog('HomeScreen: closing app via SystemNavigator.pop');
    await SystemNavigator.pop();
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
    final canExplore = ref.watch(authNotifierProvider).canAccessExplore;
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _isExiting) return;
        final now = DateTime.now();
        if (_lastBackPress != null &&
            now.difference(_lastBackPress!) < _kBackExitWindow) {
          unawaited(_gracefulExit());
          return;
        }
        _lastBackPress = now;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Press back again to exit'),
            duration: _kBackExitWindow,
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      child: Scaffold(
      body: Row(
        children: [
          Container(
            width: 328,
            decoration: BoxDecoration(
              color: AppColors.card,
              border: Border(
                right: BorderSide(
                  color: AppColors.border.withValues(alpha: 0.85),
                ),
              ),
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(20),
                bottomRight: Radius.circular(20),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 20,
                  offset: const Offset(6, 0),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: FocusScope(
              node: _sidebarScopeNode,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 18, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.border),
                            color: AppColors.highlight.withValues(alpha: 0.12),
                          ),
                          child: Image.asset(
                            'assets/icon.png',
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'TeleCima',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _isSyncing
                                    ? 'Sync in progress…'
                                    : 'Last sync · ${_formatLastSync()}',
                                style: TextStyle(
                                  color: AppColors.textMuted.withValues(
                                    alpha: 0.95,
                                  ),
                                  fontSize: 13,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: TVButton(
                        focusNode: _syncButtonFocusNode,
                        autofocus: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        onKeyEvent: (_, event) {
                          if (_isRight(event)) {
                            _focusGridFromSidebar();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        onPressed: () {
                          if (_isSyncing) {
                            setState(() => _syncCancelRequested = true);
                            _homeSyncLog('HomeScreen: sync cancel requested');
                            return;
                          }
                          _triggerSync(isManual: true);
                        },
                        child: Row(
                          children: [
                            Icon(
                              Icons.sync_rounded,
                              color: Colors.white.withValues(
                                alpha: 1,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _isSyncing
                                    ? (_syncCancelRequested
                                        ? 'Cancelling…'
                                        : 'Syncing… (press to cancel)')
                                    : 'Sync library',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: Scrollbar(
                        controller: _sidebarScrollController,
                        thumbVisibility: true,
                        radius: const Radius.circular(8),
                        thickness: 5,
                        child: CustomScrollView(
                          controller: _sidebarScrollController,
                          primary: false,
                          clipBehavior: Clip.hardEdge,
                          slivers: [
                            SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (canExplore) ...[
                                    const _SidebarSectionLabel('Explore'),
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: TVButton(
                                        focusNode: _exploreFocusNode,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 14,
                                        ),
                                        onKeyEvent: (_, event) {
                                          if (_isRight(event)) {
                                            _focusGridFromSidebar();
                                            return KeyEventResult.handled;
                                          }
                                          return KeyEventResult.ignored;
                                        },
                                        onPressed: () => context.push('/explore'),
                                        child: const Row(
                                          children: [
                                            Icon(
                                              Icons.explore_rounded,
                                              color: Colors.white,
                                            ),
                                            SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                'Browse catalog',
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                  ],
                                  const _SidebarSectionLabel(
                                    'Browse by type',
                                  ),
                                  const SizedBox(height: 10),
                                  for (var i = 0; i < 3; i++) ...[
                                    _SidebarFilterButton(
                                      focusNode: _typeFocusNodes[i],
                                      label: switch (i) {
                                        0 => 'All titles',
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
                                        ref
                                                .read(selectedTypeFilterProvider
                                                    .notifier)
                                                .state =
                                            switch (i) {
                                          0 => LibraryTypeFilter.all,
                                          1 => LibraryTypeFilter.movies,
                                          _ => LibraryTypeFilter.series,
                                        };
                                      },
                                      onFocusChanged: (focused) {
                                        if (!focused) return;
                                        WidgetsBinding.instance
                                            .addPostFrameCallback((_) {
                                          if (!mounted) return;
                                          _ensureSidebarNodeVisible(
                                            _typeFocusNodes[i],
                                          );
                                        });
                                      },
                                    ),
                                    if (i < 2) const SizedBox(height: 8),
                                  ],
                                  const SizedBox(height: 20),
                                  const _SidebarSectionLabel('Sources'),
                                  const SizedBox(height: 10),
                                ],
                              ),
                            ),
                            if (sources.isEmpty)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    top: 4,
                                    bottom: 16,
                                  ),
                                  child: Text(
                                    'No sources yet. Sync to load channels.',
                                    style: TextStyle(
                                      color: AppColors.textMuted.withValues(
                                        alpha: 0.85,
                                      ),
                                      fontSize: 14,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              )
                            else
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final source = sources[index];
                                    final isSelected =
                                        selectedSource == source.id;
                                    return Padding(
                                      padding: EdgeInsets.only(
                                        bottom:
                                            index < sources.length - 1 ? 8 : 14,
                                      ),
                                      child: _SidebarFilterButton(
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
                                              .read(
                                                selectedSourceFilterProvider
                                                    .notifier,
                                              )
                                              .state = isSelected
                                              ? null
                                              : source.id;
                                        },
                                        onFocusChanged: (focused) {
                                          if (!focused) return;
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                            if (!mounted) return;
                                            _ensureSidebarNodeVisible(
                                              _sourceFocusNodes[index],
                                            );
                                          });
                                        },
                                      ),
                                    );
                                  },
                                  childCount: sources.length,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
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
                          Icon(Icons.logout_rounded, color: Colors.white),
                          SizedBox(width: 10),
                          Text('Log out'),
                        ],
                      ),
                    ),
                  ],
                ),
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
    ),
    );
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  const _SidebarSectionLabel(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: AppColors.highlight.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: AppColors.textMuted.withValues(alpha: 0.95),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.15,
          ),
        ),
      ],
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
            width: 3,
            height: 22,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.highlight
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: AppColors.highlight.withValues(alpha: 0.45),
                        blurRadius: 6,
                      ),
                    ]
                  : null,
            ),
          ),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: TextStyle(
                color: selected
                    ? AppColors.highlight
                    : Colors.white.withValues(alpha: 0.92),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 15,
                height: 1.2,
              ),
            ),
          ),
          if (selected)
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.highlight.withValues(alpha: 0.9),
              size: 22,
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
