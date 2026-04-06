import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tdlib/td_api.dart' as td;

import '../../core/debug/app_debug_log.dart';
import '../../core/storage/storage_headroom.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/oxplayer_button.dart';
import '../../data/models/app_media.dart';
import '../../download/download_manager.dart';
import '../../providers.dart';
import '../../telegram/tdlib_facade.dart';

const _kBackExitWindow = Duration(seconds: 3);

const _kApiKindMovie = 'movie';
const _kApiKindSeries = 'series';
const _kApiKindOther = 'general_video';

/// Number of visible slots in home carousel rows.
const _kCarouselVisibleSlots = 5;
const _kCarouselGap = 10.0;
const _kCarouselSidePad = 24.0;

/// Focused tile gets wider (layout-based, not transform-based).
const _kFocusedWidthFactor = 1.5;

({double cardWidth, double sectionHorizontalPad}) _homeCarouselLayout(
  double screenW,
) {
  final bleed = (_kFocusedWidthFactor - 1) / 2;
  final cardW = (screenW -
          2 * _kCarouselSidePad -
          (_kCarouselVisibleSlots - 1) * _kCarouselGap) /
      _kCarouselVisibleSlots;
  final sectionPad = _kCarouselSidePad + cardW * bleed;
  return (cardWidth: cardW, sectionHorizontalPad: sectionPad);
}

void _homeLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

String _debugErrorSummary(Object error) {
  return switch (error) {
    td.TdError() => 'TDLib ${error.code}: ${error.message}',
    _ => '$error',
  };
}

String? _libraryPosterUrl(AppMedia media) {
  final value = (media.posterPath ?? '').trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (value.startsWith('/')) return 'https://image.tmdb.org/t/p/w500$value';
  return value;
}

String _libraryTypeLabel(String type) {
  switch (type) {
    case 'MOVIE':
    case '#movie':
      return 'Movie';
    case 'SERIES':
    case '#series':
      return 'Show';
    case 'GENERAL_VIDEO':
      return 'Video';
    default:
      return type;
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _mainTab = 0;
  bool _isRefreshingLibrary = false;
  DateTime? _lastLibraryRefreshTime;
  DateTime? _lastBackPress;
  bool _isExiting = false;

  @override
  void initState() {
    super.initState();
    _homeLog('HomeScreen: initState');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshLibraryOnOpen();
    });
  }

  Future<void> _refreshLibraryOnOpen() async {
    var auth = ref.read(authNotifierProvider);
    for (var i = 0; i < 120 && !auth.ready && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      auth = ref.read(authNotifierProvider);
    }
    if (!mounted) return;

    if (!auth.isLoggedIn) {
      _homeLog('HomeScreen: skip library refresh on open (no Telegram session)');
      return;
    }

    final config = ref.read(appConfigProvider);
    if (!config.hasApiConfig) {
      _homeLog('HomeScreen: skip library refresh on open (API not configured)');
      return;
    }

    final hasToken = (auth.apiAccessToken ?? '').isNotEmpty;
    _homeLog('HomeScreen: refresh library on open (hasApiToken=$hasToken)');
    await _refreshLibraryFromApi(notifyUserOnFailure: false);
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
        'OXPLAYER_API_BASE_URL and one of OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME / OXPLAYER_TELEGRAM_WEBAPP_URL must be set in assets/env/default.env',
      );
    }

    final tdlib = ref.read(tdlibFacadeProvider);
    final api = ref.read(oxplayerApiServiceProvider);
    _homeLog('HomeScreen: requesting fresh API access token');
    final authResult =
        await api.authenticateWithTelegram(tdlib: tdlib, config: config);
    await auth.setApiAccessToken(authResult.accessToken);
    await auth.applyFromTelegramAuthResult(
      userId: authResult.userId,
      telegramId: authResult.telegramId,
      username: authResult.username,
      firstName: authResult.firstName,
      phoneNumber: authResult.phoneNumber,
      preferredSubtitleLanguage: authResult.preferredSubtitleLanguage,
      userType: authResult.userType,
    );
    _homeLog(
      'HomeScreen: API token saved (len=${authResult.accessToken.length})',
    );
    return authResult.accessToken;
  }

  bool _isUnauthorized(DioException e) {
    final status = e.response?.statusCode;
    return status == 401 || status == 403;
  }

  void _invalidateLibraryCaches() {
    ref.invalidate(libraryFetchProvider);
    ref.invalidate(libraryMediaByKindProvider(_kApiKindMovie));
    ref.invalidate(libraryMediaByKindProvider(_kApiKindSeries));
    ref.invalidate(libraryMediaByKindProvider(_kApiKindOther));
  }

  Future<void> _refreshLibraryFromApi({
    bool notifyUserOnFailure = true,
  }) async {
    if (_isRefreshingLibrary) return;
    setState(() => _isRefreshingLibrary = true);
    _homeLog('HomeScreen: library refresh started');

    try {
      await _requireApiAccessToken();
      try {
        _invalidateLibraryCaches();
        ref.read(exploreCatalogRefreshGenerationProvider.notifier).state++;
        await ref.read(libraryFetchProvider.future);
      } on DioException catch (e) {
        if (!_isUnauthorized(e)) rethrow;

        _homeLog(
          'HomeScreen: API token rejected (status=${e.response?.statusCode}), refreshing once',
        );
        final auth = ref.read(authNotifierProvider);
        await auth.clearApiAccessToken();
        try {
          await _requireApiAccessToken();
          _invalidateLibraryCaches();
          ref.read(exploreCatalogRefreshGenerationProvider.notifier).state++;
          await ref.read(libraryFetchProvider.future);
        } catch (refreshError) {
          _homeLog(
            'HomeScreen: token refresh/retry failed, logging out: $refreshError',
          );
          await auth.clearSession();
          rethrow;
        }
      }

      if (mounted) {
        setState(() => _lastLibraryRefreshTime = DateTime.now());
      }
      _homeLog('HomeScreen: library refresh completed');
    } catch (e, st) {
      _homeLog('HomeScreen: library refresh failed: ${_debugErrorSummary(e)}');
      _homeLog(
        'HomeScreen: failure stack (head): '
        '${st.toString().split('\n').take(8).join(' | ')}',
      );
      if (e is DioException) {
        _homeLog(
          'HomeScreen: DioException details '
          'type=${e.type} status=${e.response?.statusCode} '
          'uri=${e.requestOptions.uri} '
          'response=${e.response?.data}',
        );
      }
      if (e is td.TdError) {
        _homeLog(
          'HomeScreen: TdError details code=${e.code} message=${e.message}',
        );
      }
      if (mounted && notifyUserOnFailure) {
        final message = switch (e) {
          TdlibInteractiveLoginRequired _ => e.toString(),
          DioException _ =>
            'Could not load library: HTTP ${e.response?.statusCode ?? '-'} ${e.requestOptions.path}\n${e.message}',
          td.TdError _ => 'Could not load library: TDLib ${e.code}: ${e.message}',
          _ => 'Could not load library: $e',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshingLibrary = false);
      _homeLog('HomeScreen: library refresh finished');
    }
  }

  String _formatLastLibraryRefresh() {
    if (_lastLibraryRefreshTime == null) return 'Never';
    final diff = DateTime.now().difference(_lastLibraryRefreshTime!);
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
    final id = item.media.id.trim();
    if (id.isEmpty) return;
    context.push('/item/${Uri.encodeComponent(id)}');
  }

  Future<void> _showStorageManageDialog(BuildContext context) async {
    final dm = ref.read(downloadManagerProvider).valueOrNull;
    if (dm == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _StorageManageDialog(dm: dm),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final canExplore = auth.canAccessExplore;
    final downloadMgrAsync = ref.watch(downloadManagerProvider);
    final showStorageCacheButton = downloadMgrAsync.hasValue &&
        downloadMgrAsync.requireValue.hasLocalStorageFootprintQuick();

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
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _NetflixTopBar(
                selectedTab: _mainTab,
                onSelectTab: (i) => setState(() => _mainTab = i),
                isRefreshing: _isRefreshingLibrary,
                lastRefreshLabel: _formatLastLibraryRefresh(),
                canExplore: canExplore,
                showStorageButton: showStorageCacheButton,
                onRefresh: () {
                  if (_isRefreshingLibrary) return;
                  unawaited(_refreshLibraryFromApi());
                },
                onExplore: () => context.push('/explore'),
                onStorage: () => unawaited(_showStorageManageDialog(context)),
                onLogout: () async {
                  await ref.read(authNotifierProvider).clearSession();
                  if (!context.mounted) return;
                  context.go('/welcome');
                },
              ),
              Expanded(
                child: IndexedStack(
                  index: _mainTab,
                  children: [
                    _HomeTabContent(
                      onOpenItem: (item) => _openItem(context, item),
                    ),
                    _SourcesTabContent(
                      onOpenItem: (item) => _openItem(context, item),
                    ),
                    const _MyOxTabContent(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NetflixTopBar extends StatelessWidget {
  const _NetflixTopBar({
    required this.selectedTab,
    required this.onSelectTab,
    required this.isRefreshing,
    required this.lastRefreshLabel,
    required this.canExplore,
    required this.showStorageButton,
    required this.onRefresh,
    required this.onExplore,
    required this.onStorage,
    required this.onLogout,
  });

  final int selectedTab;
  final ValueChanged<int> onSelectTab;
  final bool isRefreshing;
  final String lastRefreshLabel;
  final bool canExplore;
  final bool showStorageButton;
  final VoidCallback onRefresh;
  final VoidCallback onExplore;
  final VoidCallback onStorage;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            'OXPlayer',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(width: 28),
          _TopNavLabel(
            label: 'Home',
            selected: selectedTab == 0,
            onTap: () => onSelectTab(0),
          ),
          const SizedBox(width: 18),
          _TopNavLabel(
            label: 'Sources',
            selected: selectedTab == 1,
            onTap: () => onSelectTab(1),
          ),
          const SizedBox(width: 18),
          _TopNavLabel(
            label: 'My OX',
            selected: selectedTab == 2,
            onTap: () => onSelectTab(2),
          ),
          const Spacer(),
          Text(
            'Synced $lastRefreshLabel',
            style: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.9),
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          if (canExplore)
            TextButton(
              onPressed: onExplore,
              child: const Text('Explore'),
            ),
          IconButton(
            tooltip: 'Refresh library',
            onPressed: isRefreshing ? null : onRefresh,
            icon: isRefreshing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          if (showStorageButton)
            IconButton(
              tooltip: 'Storage & cache',
              onPressed: onStorage,
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
          IconButton(
            tooltip: 'Log out',
            onPressed: onLogout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
    );
  }
}

class _TopNavLabel extends StatelessWidget {
  const _TopNavLabel({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 2,
              width: selected ? 28 : 0,
              decoration: BoxDecoration(
                color: AppColors.highlight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeTabContent extends ConsumerWidget {
  const _HomeTabContent({required this.onOpenItem});

  final void Function(AppMediaAggregate item) onOpenItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = MediaQuery.sizeOf(context).width;
    final layout = _homeCarouselLayout(w);
    final cardW = layout.cardWidth;
    final sectionHPad = layout.sectionHorizontalPad;
    final posterH = cardW * 1.5;
    const textBlockH = 120.0;
    final rowH = posterH + textBlockH;

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _HomeKindRow(
          title: 'Movies',
          apiKind: _kApiKindMovie,
          cardWidth: cardW,
          posterHeight: posterH,
          rowHeight: rowH,
          gap: _kCarouselGap,
          sectionHorizontalPad: sectionHPad,
          onOpenItem: onOpenItem,
        ),
        const SizedBox(height: 8),
        _HomeKindRow(
          title: 'Shows',
          apiKind: _kApiKindSeries,
          cardWidth: cardW,
          posterHeight: posterH,
          rowHeight: rowH,
          gap: _kCarouselGap,
          sectionHorizontalPad: sectionHPad,
          onOpenItem: onOpenItem,
        ),
        const SizedBox(height: 8),
        _HomeKindRow(
          title: 'Other',
          apiKind: _kApiKindOther,
          cardWidth: cardW,
          posterHeight: posterH,
          rowHeight: rowH,
          gap: _kCarouselGap,
          sectionHorizontalPad: sectionHPad,
          onOpenItem: onOpenItem,
        ),
      ],
    );
  }
}

class _HomeKindRow extends ConsumerStatefulWidget {
  const _HomeKindRow({
    required this.title,
    required this.apiKind,
    required this.cardWidth,
    required this.posterHeight,
    required this.rowHeight,
    required this.gap,
    required this.sectionHorizontalPad,
    required this.onOpenItem,
  });

  final String title;
  final String apiKind;
  final double cardWidth;
  final double posterHeight;
  final double rowHeight;
  final double gap;
  final double sectionHorizontalPad;
  final void Function(AppMediaAggregate item) onOpenItem;

  @override
  ConsumerState<_HomeKindRow> createState() => _HomeKindRowState();
}

class _HomeKindRowState extends ConsumerState<_HomeKindRow> {
  final ScrollController _scrollController = ScrollController();
  final List<FocusNode> _focusNodes = <FocusNode>[];
  int? _focusedIndex;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _HomeKindRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKind != widget.apiKind) {
      _focusedIndex = null;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    for (final n in _focusNodes) {
      n.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _syncFocusNodes(int count) {
    if (_focusNodes.length == count) return;
    if (_focusNodes.length > count) {
      for (var i = count; i < _focusNodes.length; i++) {
        _focusNodes[i].dispose();
      }
      _focusNodes.removeRange(count, _focusNodes.length);
      return;
    }
    for (var i = _focusNodes.length; i < count; i++) {
      _focusNodes.add(FocusNode(debugLabel: 'home-row-item-$i'));
    }
  }

  double _itemExtentFor(int index) {
    final focusedW = widget.cardWidth * _kFocusedWidthFactor;
    return (index == _focusedIndex ? focusedW : widget.cardWidth) + widget.gap;
  }

  double _scrollOffsetForStart(int index) {
    var acc = 0.0;
    for (var i = 0; i < index; i++) {
      acc += _itemExtentFor(i);
    }
    return acc;
  }

  void _ensureFocusedVisible(int itemCount) {
    final focusedIndex = _focusedIndex;
    if (focusedIndex == null) return;
    if (!_scrollController.hasClients || itemCount <= 0) return;
    final focusedW = widget.cardWidth * _kFocusedWidthFactor;
    final left = _scrollOffsetForStart(focusedIndex);
    final right = left + focusedW;
    final viewLeft = _scrollController.offset;
    final viewRight = viewLeft + _scrollController.position.viewportDimension;

    var target = viewLeft;
    if (left < viewLeft) {
      target = left;
    } else if (right > viewRight) {
      target = right - _scrollController.position.viewportDimension;
    }
    target = target.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    if ((target - _scrollController.offset).abs() > 0.5) {
      _scrollController.jumpTo(target.toDouble());
    }
  }

  void _moveFocus(int delta, int itemCount) {
    if (itemCount <= 0) return;
    final current = _focusedIndex;
    if (current == null) return;
    final next = (current + delta).clamp(0, itemCount - 1);
    if (next == current) return;
    setState(() => _focusedIndex = next);
    if (next < _focusNodes.length) {
      _focusNodes[next].requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensureFocusedVisible(itemCount);
    });
  }

  void _activateCurrent(List<AppMediaAggregate> slice, int itemCount) {
    final focusedIndex = _focusedIndex;
    if (focusedIndex == null || focusedIndex < 0 || focusedIndex >= itemCount) {
      return;
    }
    if (focusedIndex >= slice.length) {
      context.push('/library/${Uri.encodeComponent(widget.apiKind)}');
    } else {
      widget.onOpenItem(slice[focusedIndex]);
    }
  }

  KeyEventResult _onItemKey(
    int index,
    KeyEvent event,
    List<AppMediaAggregate> slice,
    int itemCount,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_focusedIndex != index) {
      setState(() => _focusedIndex = index);
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (index == 0) return KeyEventResult.handled;
      _moveFocus(-1, itemCount);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (index == itemCount - 1) return KeyEventResult.handled;
      _moveFocus(1, itemCount);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      _activateCurrent(slice, itemCount);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(libraryMediaByKindProvider(widget.apiKind));

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.sectionHorizontalPad),
            child: Text(
              widget.title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: widget.rowHeight,
            child: async.when(
              data: (items) {
                final slice = items.take(10).toList();
                final n = slice.length + 1;
                _syncFocusNodes(n);
                if (_focusedIndex != null && _focusedIndex! >= n) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    setState(() => _focusedIndex = null);
                  });
                }
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.sectionHorizontalPad,
                  ),
                  child: ListView.separated(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    itemCount: n,
                    separatorBuilder: (_, __) => SizedBox(width: widget.gap),
                    itemBuilder: (context, index) {
                      final selected = index == _focusedIndex;
                      final isShowMore = index == slice.length;
                      final width = (selected && !isShowMore)
                          ? widget.cardWidth * _kFocusedWidthFactor
                          : widget.cardWidth;
                      return Focus(
                        focusNode: _focusNodes[index],
                        onFocusChange: (hasFocus) {
                          if (hasFocus) {
                            if (_focusedIndex == index) return;
                            setState(() => _focusedIndex = index);
                            _ensureFocusedVisible(n);
                            return;
                          }
                          if (_focusedIndex != index) return;
                          setState(() => _focusedIndex = null);
                          _ensureFocusedVisible(n);
                        },
                        onKeyEvent: (_, e) => _onItemKey(index, e, slice, n),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          width: width,
                          child: index == slice.length
                              ? _CarouselShowMoreCard(
                                  posterHeight: widget.posterHeight,
                                  selected: selected,
                                  onTap: () => context.push(
                                    '/library/${Uri.encodeComponent(widget.apiKind)}',
                                  ),
                                )
                              : _CarouselMediaCard(
                                  posterHeight: widget.posterHeight,
                                  item: slice[index],
                                  selected: selected,
                                  onTap: () => widget.onOpenItem(slice[index]),
                                ),
                        ),
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.sectionHorizontalPad,
                  ),
                  child: Text(
                    'Could not load ${widget.title}.\n$e',
                    style: const TextStyle(color: AppColors.textMuted),
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

class _CarouselMediaCard extends StatelessWidget {
  const _CarouselMediaCard({
    required this.posterHeight,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final double posterHeight;
  final AppMediaAggregate item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = item.media;
    final url = _libraryPosterUrl(m);
    final type = _libraryTypeLabel(m.type);
    final summary = (m.summary ?? '').trim();
    final scoreText =
        m.voteAverage != null ? m.voteAverage!.toStringAsFixed(1) : '—';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              elevation: selected ? 8 : 0,
              shadowColor: Colors.black,
              surfaceTintColor: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.9)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: posterHeight,
                  child: url == null
                      ? Container(
                          color: Colors.black26,
                          alignment: Alignment.center,
                          child: const Icon(Icons.movie, size: 40),
                        )
                      : CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            color: Colors.black26,
                            alignment: Alignment.center,
                            child: const Icon(Icons.broken_image, size: 32),
                          ),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          m.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: selected ? 14.5 : 13,
                            height: 1.2,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            scoreText,
                            style: TextStyle(
                              color: AppColors.highlight,
                              fontWeight: FontWeight.w800,
                              fontSize: selected ? 14 : 12,
                              height: 1.1,
                            ),
                          ),
                          Text(
                            '/10',
                            style: TextStyle(
                              color: AppColors.textMuted.withValues(alpha: 0.85),
                              fontSize: selected ? 10 : 9,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (selected && summary.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      summary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 4),
                    Text(
                      type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CarouselShowMoreCard extends StatelessWidget {
  const _CarouselShowMoreCard({
    required this.posterHeight,
    required this.selected,
    required this.onTap,
  });

  final double posterHeight;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            Material(
              color: AppColors.card.withValues(alpha: selected ? 0.85 : 0.65),
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              elevation: selected ? 6 : 0,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.85)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                height: posterHeight,
                width: double.infinity,
                child: Center(
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 42,
                    color: AppColors.highlight.withValues(alpha: 0.95),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(6, 10, 6, 4),
              child: Text(
                'Show more',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourcesTabContent extends ConsumerWidget {
  const _SourcesTabContent({required this.onOpenItem});

  final void Function(AppMediaAggregate item) onOpenItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(libraryFetchProvider);

    return async.when(
      data: (result) {
        final items = result.items;
        if (items.isEmpty) {
          return const Center(
            child: Text(
              'No library items yet.',
              style: TextStyle(color: AppColors.textMuted),
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, c) {
            const gap = 10.0;
            const pad = 16.0;
            final w = c.maxWidth - pad * 2;
            const cols = 5;
            final cellW = (w - gap * (cols - 1)) / cols;
            final posterH = cellW * 1.5;
            final cellH = posterH + 52;
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(pad, 8, pad, 28),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                childAspectRatio: cellW / cellH,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final m = item.media;
                final url = _libraryPosterUrl(m);
                return Material(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onOpenItem(item),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: url == null
                              ? Container(
                                  color: Colors.black26,
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.movie, size: 32),
                                )
                              : CachedNetworkImage(
                                  imageUrl: url,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => const Center(
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                  errorWidget: (_, __, ___) => Container(
                                    color: Colors.black26,
                                    alignment: Alignment.center,
                                    child: const Icon(Icons.broken_image,
                                        size: 28),
                                  ),
                                ),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(6, 6, 6, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  height: 1.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _libraryTypeLabel(m.type),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          'Could not load library.\n$e',
          style: const TextStyle(color: AppColors.textMuted),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _MyOxTabContent extends StatelessWidget {
  const _MyOxTabContent();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'My OX\n\nPersonal shelf placeholder — layout TBD.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 16,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

/// Local downloads + Telegram cache management.
class _StorageManageDialog extends StatefulWidget {
  const _StorageManageDialog({required this.dm});

  final DownloadManager dm;

  @override
  State<_StorageManageDialog> createState() => _StorageManageDialogState();
}

class _StorageManageDialogState extends State<_StorageManageDialog> {
  LocalMediaStorageStats? _stats;
  bool _loading = true;
  String? _error;
  bool _clearingCache = false;
  bool _clearingAll = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reloadStats());
  }

  Future<void> _reloadStats({bool showLoadingSpinner = true}) async {
    if (showLoadingSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final s = await widget.dm.queryLocalMediaStorageStats();
      if (!mounted) return;
      setState(() {
        _stats = s;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _onClearCache() async {
    if (_stats == null || _stats!.cacheBytes <= 0 || _clearingCache) return;
    setState(() => _clearingCache = true);
    try {
      await widget.dm.clearTelegramTemporaryCache();
      if (!mounted) return;
      await _reloadStats(showLoadingSpinner: false);
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  Future<void> _onClearAll() async {
    if (_stats == null || _stats!.totalBytes <= 0 || _clearingAll) return;
    setState(() => _clearingAll = true);
    try {
      await widget.dm.clearAllDownloadsAndCache();
      if (!mounted) return;
      await _reloadStats(showLoadingSpinner: false);
    } finally {
      if (mounted) setState(() => _clearingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text(
        'Storage & cache',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : _error != null
                ? Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'This screen shows video files saved on this device '
                          'through OXPlayer (finished downloads) and temporary data '
                          'Telegram keeps while you stream or pause a download. '
                          'Clear cache frees that temporary data only. Clear all '
                          'removes saved files and download history on this device.',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            height: 1.4,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Downloaded on this device (${_stats!.downloadedFiles.length})',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_stats!.downloadedFiles.isEmpty)
                          const Text(
                            'No finished downloads on this device.',
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 14,
                            ),
                          )
                        else
                          ..._stats!.downloadedFiles.map(
                            (e) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      e.label,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    formatStorageHuman(e.bytes),
                                    style: const TextStyle(
                                      color: AppColors.textMuted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
      ),
      actions: [
        FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              if (!_loading && _error == null && _stats != null) ...[
                OxplayerButton(
                  enabled: !_clearingCache &&
                      !_clearingAll &&
                      _stats!.cacheBytes > 0,
                  onPressed: () => unawaited(_onClearCache()),
                  child: _clearingCache
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          'Clear cache (${formatStorageHuman(_stats!.cacheBytes)})',
                          style: const TextStyle(color: Colors.white),
                        ),
                ),
                OxplayerButton(
                  enabled: !_clearingCache &&
                      !_clearingAll &&
                      _stats!.totalBytes > 0,
                  onPressed: () => unawaited(_onClearAll()),
                  child: _clearingAll
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          'Clear all (${formatStorageHuman(_stats!.totalBytes)})',
                          style: const TextStyle(color: Colors.white),
                        ),
                ),
              ],
              OxplayerButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Close',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
