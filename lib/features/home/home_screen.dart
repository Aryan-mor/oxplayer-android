import 'dart:async';

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
import '../../widgets/library_media_poster.dart';

const _kBackExitWindow = Duration(seconds: 3);

const _kApiKindMovie = 'movie';
const _kApiKindSeries = 'series';
const _kApiKindOther = 'general_video';

/// Number of visible slots in home carousel rows.
const _kCarouselVisibleSlots = 5;
const _kCarouselGap = 10.0;

/// Focused tile gets wider (layout-based, not transform-based).
const _kFocusedWidthFactor = 1.5;

({double cardWidth, double sectionHorizontalPad}) _homeCarouselLayout(
  double screenW,
) {
  final sidePad = AppLayout.tvHorizontalInset;
  final bleed = (_kFocusedWidthFactor - 1) / 2;
  final cardW = (screenW -
          2 * sidePad -
          (_kCarouselVisibleSlots - 1) * _kCarouselGap) /
      _kCarouselVisibleSlots;
  final sectionPad = sidePad + cardW * bleed;
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
  final GlobalKey<_HomeTabContentState> _homeTabKey =
      GlobalKey<_HomeTabContentState>();
  final GlobalKey<_SourcesTabContentState> _sourcesTabKey =
      GlobalKey<_SourcesTabContentState>();

  late final FocusNode _homeNavFocus =
      FocusNode(debugLabel: 'home-nav-home');
  late final FocusNode _sourcesNavFocus =
      FocusNode(debugLabel: 'home-nav-sources');
  late final FocusNode _myOxNavFocus =
      FocusNode(debugLabel: 'home-nav-myox');
  late final FocusNode _exploreFocus =
      FocusNode(debugLabel: 'home-nav-explore');
  late final FocusNode _refreshFocus =
      FocusNode(debugLabel: 'home-action-refresh');
  late final FocusNode _storageFocus =
      FocusNode(debugLabel: 'home-action-storage');
  late final FocusNode _logoutFocus =
      FocusNode(debugLabel: 'home-action-logout');

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
      _applyResumeOrDefaultFocus();
    });
  }

  @override
  void dispose() {
    _homeNavFocus.dispose();
    _sourcesNavFocus.dispose();
    _myOxNavFocus.dispose();
    _exploreFocus.dispose();
    _refreshFocus.dispose();
    _storageFocus.dispose();
    _logoutFocus.dispose();
    super.dispose();
  }

  void _applyResumeOrDefaultFocus() {
    if (!mounted) return;
    final snap = ref.read(homeBrowseFocusProvider);
    if (!snap.expectResumeAfterDetail) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _homeNavFocus.requestFocus();
      });
      return;
    }

    ref.read(homeBrowseFocusProvider.notifier).clearResumeExpectation();

    final tab = snap.lastMainTab;
    if (tab != _mainTab) {
      setState(() => _mainTab = tab);
    }

    void tryResume({int attempt = 0}) {
      if (!mounted) return;
      if (tab == 0) {
        final kind = snap.lastCarouselApiKind;
        final idx = snap.lastCarouselItemIndex;
        final row = switch (kind) {
          _kApiKindMovie => 0,
          _kApiKindSeries => 1,
          _kApiKindOther => 2,
          _ => -1,
        };
        if (row >= 0) {
          final ok =
              _homeTabKey.currentState?.focusCarouselRow(row, idx) ?? false;
          if (ok) return;
          if (attempt < 12) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => tryResume(attempt: attempt + 1));
            return;
          }
        }
      } else if (tab == 1) {
        final ok = _sourcesTabKey.currentState
                ?.focusGridIndex(snap.lastSourcesGridIndex) ??
            false;
        if (ok) return;
        if (attempt < 12) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => tryResume(attempt: attempt + 1));
          return;
        }
      }
      if (tab == 0) {
        _homeNavFocus.requestFocus();
      } else if (tab == 1) {
        _sourcesNavFocus.requestFocus();
      } else {
        _myOxNavFocus.requestFocus();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tryResume());
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
    ref.read(homeBrowseFocusProvider.notifier).markOpeningDetail();
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
                homeNavFocus: _homeNavFocus,
                sourcesNavFocus: _sourcesNavFocus,
                myOxNavFocus: _myOxNavFocus,
                exploreFocus: _exploreFocus,
                refreshFocus: _refreshFocus,
                storageFocus: _storageFocus,
                logoutFocus: _logoutFocus,
                onSelectTab: (i) {
                  setState(() => _mainTab = i);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    switch (i) {
                      case 0:
                        _homeNavFocus.requestFocus();
                        break;
                      case 1:
                        _sourcesNavFocus.requestFocus();
                        break;
                      default:
                        _myOxNavFocus.requestFocus();
                    }
                  });
                },
                onNavArrowDown: (navIndex) {
                  if (navIndex == 0 && _mainTab == 0) {
                    _homeTabKey.currentState?.focusFirstCarouselTile();
                  } else if (navIndex == 1 && _mainTab == 1) {
                    _sourcesTabKey.currentState?.focusFirstGridTile();
                  }
                },
                onHeaderFocusedWhileHomeTab: () {
                  _homeTabKey.currentState?.clearActiveSection();
                },
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
                      key: _homeTabKey,
                      headerHomeNavFocus: _homeNavFocus,
                      onOpenItem: (item) => _openItem(context, item),
                    ),
                    _SourcesTabContent(
                      key: _sourcesTabKey,
                      sourcesNavFocus: _sourcesNavFocus,
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
    required this.homeNavFocus,
    required this.sourcesNavFocus,
    required this.myOxNavFocus,
    required this.exploreFocus,
    required this.refreshFocus,
    required this.storageFocus,
    required this.logoutFocus,
    required this.onNavArrowDown,
    required this.onHeaderFocusedWhileHomeTab,
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
  final FocusNode homeNavFocus;
  final FocusNode sourcesNavFocus;
  final FocusNode myOxNavFocus;
  final FocusNode exploreFocus;
  final FocusNode refreshFocus;
  final FocusNode storageFocus;
  final FocusNode logoutFocus;
  final void Function(int navIndex) onNavArrowDown;
  final VoidCallback onHeaderFocusedWhileHomeTab;
  final bool isRefreshing;
  final String lastRefreshLabel;
  final bool canExplore;
  final bool showStorageButton;
  final VoidCallback onRefresh;
  final VoidCallback onExplore;
  final VoidCallback onStorage;
  final VoidCallback onLogout;

  KeyEventResult _navDownKey(int navIndex, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      onNavArrowDown(navIndex);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.tvTopBarHorizontalPad,
        10,
        AppLayout.tvTopBarHorizontalPad,
        14,
      ),
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
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
            const SizedBox(width: 24),
            OxplayerButton(
              focusNode: homeNavFocus,
              selected: selectedTab == 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              borderRadius: 8,
              onPressed: () => onSelectTab(0),
              onFocusChanged: (f) {
                if (f) onHeaderFocusedWhileHomeTab();
              },
              onKeyEvent: (_, e) => _navDownKey(0, e),
              child: _topNavLabelChild('Home', selectedTab == 0),
            ),
            const SizedBox(width: 10),
            OxplayerButton(
              focusNode: sourcesNavFocus,
              selected: selectedTab == 1,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              borderRadius: 8,
              onPressed: () => onSelectTab(1),
              onKeyEvent: (_, e) => _navDownKey(1, e),
              child: _topNavLabelChild('Sources', selectedTab == 1),
            ),
            const SizedBox(width: 10),
            OxplayerButton(
              focusNode: myOxNavFocus,
              selected: selectedTab == 2,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              borderRadius: 8,
              onPressed: () => onSelectTab(2),
              onKeyEvent: (_, e) => _navDownKey(2, e),
              child: _topNavLabelChild('My OX', selectedTab == 2),
            ),
            const Spacer(),
            Text(
              'Synced $lastRefreshLabel',
              style: TextStyle(
                color: AppColors.textMuted.withValues(alpha: 0.9),
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 12),
            if (canExplore) ...[
              OxplayerButton(
                focusNode: exploreFocus,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                borderRadius: 8,
                onPressed: onExplore,
                child: const Text(
                  'Explore',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
            ],
            OxplayerButton(
              focusNode: refreshFocus,
              enabled: !isRefreshing,
              padding: const EdgeInsets.all(12),
              borderRadius: 10,
              onPressed: onRefresh,
              child: isRefreshing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 24),
            ),
            if (showStorageButton) ...[
              const SizedBox(width: 4),
              OxplayerButton(
                focusNode: storageFocus,
                padding: const EdgeInsets.all(12),
                borderRadius: 10,
                onPressed: onStorage,
                child: const Icon(Icons.delete_sweep_rounded, size: 24),
              ),
            ],
            const SizedBox(width: 4),
            OxplayerButton(
              focusNode: logoutFocus,
              padding: const EdgeInsets.all(12),
              borderRadius: 10,
              onPressed: onLogout,
              child: const Icon(Icons.logout_rounded, size: 24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topNavLabelChild(String label, bool selected) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? Colors.white : AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 4),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 2,
          width: 28,
          decoration: BoxDecoration(
            color: selected ? AppColors.highlight : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}

class _HomeTabContent extends ConsumerStatefulWidget {
  const _HomeTabContent({
    super.key,
    required this.headerHomeNavFocus,
    required this.onOpenItem,
  });

  final FocusNode headerHomeNavFocus;
  final void Function(AppMediaAggregate item) onOpenItem;

  @override
  ConsumerState<_HomeTabContent> createState() => _HomeTabContentState();
}

class _HomeTabContentState extends ConsumerState<_HomeTabContent> {
  final GlobalKey<_HomeKindRowState> _movieRowKey = GlobalKey();
  final GlobalKey<_HomeKindRowState> _showRowKey = GlobalKey();
  final GlobalKey<_HomeKindRowState> _otherRowKey = GlobalKey();

  final ScrollController _homeVerticalScroll = ScrollController();
  final GlobalKey _rowViewportKey0 = GlobalKey();
  final GlobalKey _rowViewportKey1 = GlobalKey();
  final GlobalKey _rowViewportKey2 = GlobalKey();

  int? _activeSectionIndex;

  @override
  void dispose() {
    _homeVerticalScroll.dispose();
    super.dispose();
  }

  void _ensureSectionVisible(int sectionIndex) {
    final key = switch (sectionIndex) {
      0 => _rowViewportKey0,
      1 => _rowViewportKey1,
      2 => _rowViewportKey2,
      _ => null,
    };
    if (key == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = key.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.08,
      );
    });
  }

  void clearActiveSection() {
    if (_activeSectionIndex != null) {
      setState(() => _activeSectionIndex = null);
    }
  }

  void _onSectionFocused(int sectionIndex) {
    if (_activeSectionIndex != sectionIndex) {
      setState(() => _activeSectionIndex = sectionIndex);
    }
    _ensureSectionVisible(sectionIndex);
  }

  bool focusCarouselRow(int rowIndex, int itemIndex) {
    final key = switch (rowIndex) {
      0 => _movieRowKey,
      1 => _showRowKey,
      2 => _otherRowKey,
      _ => null,
    };
    final ok = key?.currentState?.focusItem(itemIndex) ?? false;
    if (ok) {
      _ensureSectionVisible(rowIndex);
    }
    return ok;
  }

  void focusFirstCarouselTile() {
    void attempt(int n) {
      if (!mounted) return;
      if (_movieRowKey.currentState?.focusItem(0) ?? false) return;
      if (n < 15) {
        WidgetsBinding.instance.addPostFrameCallback((_) => attempt(n + 1));
      }
    }

    attempt(0);
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final layout = _homeCarouselLayout(w);
    final cardW = layout.cardWidth;
    final sectionHPad = layout.sectionHorizontalPad;
    final posterH = cardW * 1.5;
    const textBlockH = 120.0;
    final rowH = posterH + textBlockH;

    double dimFor(int section) {
      if (_activeSectionIndex == null) return 1;
      return _activeSectionIndex == section ? 1 : 0.45;
    }

    return ListView(
      controller: _homeVerticalScroll,
      padding: const EdgeInsets.only(
        bottom: AppLayout.screenBottomInset + AppLayout.tvSectionVerticalGap,
      ),
      children: [
        AnimatedOpacity(
          key: _rowViewportKey0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          opacity: dimFor(0),
          child: _HomeKindRow(
            key: _movieRowKey,
            sectionIndex: 0,
            title: 'Movies',
            apiKind: _kApiKindMovie,
            cardWidth: cardW,
            posterHeight: posterH,
            rowHeight: rowH,
            gap: _kCarouselGap,
            sectionHorizontalPad: sectionHPad,
            titleEmphasized: _activeSectionIndex == 0,
            onSectionFocused: _onSectionFocused,
            onArrowUpFrom: (_) => widget.headerHomeNavFocus.requestFocus(),
            onArrowDownFrom: (i) =>
                _showRowKey.currentState?.focusItem(_clampToRow(_showRowKey, i)),
            onOpenItem: widget.onOpenItem,
          ),
        ),
        const SizedBox(height: AppLayout.tvSectionVerticalGap),
        AnimatedOpacity(
          key: _rowViewportKey1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          opacity: dimFor(1),
          child: _HomeKindRow(
            key: _showRowKey,
            sectionIndex: 1,
            title: 'Shows',
            apiKind: _kApiKindSeries,
            cardWidth: cardW,
            posterHeight: posterH,
            rowHeight: rowH,
            gap: _kCarouselGap,
            sectionHorizontalPad: sectionHPad,
            titleEmphasized: _activeSectionIndex == 1,
            onSectionFocused: _onSectionFocused,
            onArrowUpFrom: (i) =>
                _movieRowKey.currentState?.focusItem(_clampToRow(_movieRowKey, i)),
            onArrowDownFrom: (i) =>
                _otherRowKey.currentState?.focusItem(_clampToRow(_otherRowKey, i)),
            onOpenItem: widget.onOpenItem,
          ),
        ),
        const SizedBox(height: AppLayout.tvSectionVerticalGap),
        AnimatedOpacity(
          key: _rowViewportKey2,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          opacity: dimFor(2),
          child: _HomeKindRow(
            key: _otherRowKey,
            sectionIndex: 2,
            title: 'Other',
            apiKind: _kApiKindOther,
            cardWidth: cardW,
            posterHeight: posterH,
            rowHeight: rowH,
            gap: _kCarouselGap,
            sectionHorizontalPad: sectionHPad,
            titleEmphasized: _activeSectionIndex == 2,
            onSectionFocused: _onSectionFocused,
            onArrowUpFrom: (i) =>
                _showRowKey.currentState?.focusItem(_clampToRow(_showRowKey, i)),
            onArrowDownFrom: (_) {},
            onOpenItem: widget.onOpenItem,
          ),
        ),
      ],
    );
  }

  int _clampToRow(GlobalKey<_HomeKindRowState> rowKey, int index) {
    final n = rowKey.currentState?.lastBuiltItemCount;
    if (n == null || n <= 0) return 0;
    return index.clamp(0, n - 1);
  }
}

class _HomeKindRow extends ConsumerStatefulWidget {
  const _HomeKindRow({
    super.key,
    required this.sectionIndex,
    required this.title,
    required this.apiKind,
    required this.cardWidth,
    required this.posterHeight,
    required this.rowHeight,
    required this.gap,
    required this.sectionHorizontalPad,
    required this.titleEmphasized,
    required this.onSectionFocused,
    required this.onArrowUpFrom,
    required this.onArrowDownFrom,
    required this.onOpenItem,
  });

  final int sectionIndex;
  final String title;
  final String apiKind;
  final double cardWidth;
  final double posterHeight;
  final double rowHeight;
  final double gap;
  final double sectionHorizontalPad;
  final bool titleEmphasized;
  final ValueChanged<int> onSectionFocused;
  final void Function(int itemIndex) onArrowUpFrom;
  final void Function(int itemIndex) onArrowDownFrom;
  final void Function(AppMediaAggregate item) onOpenItem;

  @override
  ConsumerState<_HomeKindRow> createState() => _HomeKindRowState();
}

class _HomeKindRowState extends ConsumerState<_HomeKindRow> {
  final ScrollController _scrollController = ScrollController();
  final List<FocusNode> _focusNodes = <FocusNode>[];
  int? _focusedIndex;
  int? _lastItemCount;

  @override
  void didUpdateWidget(covariant _HomeKindRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKind != widget.apiKind) {
      _focusedIndex = null;
      _lastItemCount = null;
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

  int? get lastBuiltItemCount => _lastItemCount;

  bool focusItem(int index) {
    final n = _lastItemCount;
    if (n == null || n <= 0 || index < 0 || index >= n) return false;
    _syncFocusNodes(n);
    setState(() => _focusedIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (index < _focusNodes.length) {
        _focusNodes[index].requestFocus();
        _ensureFocusedVisible(n);
      }
    });
    return true;
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
      _focusNodes.add(
        FocusNode(debugLabel: 'home-${widget.apiKind}-$i'),
      );
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
    ref.read(homeBrowseFocusProvider.notifier).setCarouselTileFocus(
          mainTab: 0,
          apiKind: widget.apiKind,
          itemIndex: focusedIndex,
        );
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
    if (k == LogicalKeyboardKey.arrowUp) {
      widget.onArrowUpFrom(index);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      widget.onArrowDownFrom(index);
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
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.sectionHorizontalPad),
            child: Text(
              widget.title,
              style: TextStyle(
                fontSize: widget.titleEmphasized ? 22 : 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
                color: widget.titleEmphasized ? Colors.white : AppColors.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: widget.rowHeight,
            child: async.when(
              data: (items) {
                final slice = items.take(10).toList();
                final n = slice.length + 1;
                _lastItemCount = n;
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
                            ref
                                .read(homeBrowseFocusProvider.notifier)
                                .setCarouselTileFocus(
                                  mainTab: 0,
                                  apiKind: widget.apiKind,
                                  itemIndex: index,
                                );
                            widget.onSectionFocused(widget.sectionIndex);
                            if (_focusedIndex == index) {
                              _ensureFocusedVisible(n);
                              return;
                            }
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
                                  onTap: () {
                                    ref
                                        .read(homeBrowseFocusProvider.notifier)
                                        .setCarouselTileFocus(
                                          mainTab: 0,
                                          apiKind: widget.apiKind,
                                          itemIndex: index,
                                        );
                                    context.push(
                                      '/library/${Uri.encodeComponent(widget.apiKind)}',
                                    );
                                  },
                                )
                              : _CarouselMediaCard(
                                  posterHeight: widget.posterHeight,
                                  item: slice[index],
                                  selected: selected,
                                  onTap: () {
                                    ref
                                        .read(homeBrowseFocusProvider.notifier)
                                        .setCarouselTileFocus(
                                          mainTab: 0,
                                          apiKind: widget.apiKind,
                                          itemIndex: index,
                                        );
                                    widget.onOpenItem(slice[index]);
                                  },
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

class _CarouselMediaCard extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final m = item.media;
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
                  child: LibraryMediaPoster(
                    media: m,
                    files: item.files,
                    placeholderIconSize: 40,
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

class _SourcesTabContent extends ConsumerStatefulWidget {
  const _SourcesTabContent({
    super.key,
    required this.sourcesNavFocus,
    required this.onOpenItem,
  });

  final FocusNode sourcesNavFocus;
  final void Function(AppMediaAggregate item) onOpenItem;

  @override
  ConsumerState<_SourcesTabContent> createState() => _SourcesTabContentState();
}

class _SourcesTabContentState extends ConsumerState<_SourcesTabContent> {
  static const int _cols = 5;

  final List<FocusNode> _focusNodes = <FocusNode>[];
  int? _focusedIndex;
  int? _lastItemCount;

  @override
  void dispose() {
    for (final n in _focusNodes) {
      n.dispose();
    }
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
      _focusNodes.add(FocusNode(debugLabel: 'sources-grid-$i'));
    }
  }

  int? get lastBuiltItemCount => _lastItemCount;

  bool focusGridIndex(int index) {
    final n = _lastItemCount;
    if (n == null || n <= 0 || index < 0 || index >= n) return false;
    _syncFocusNodes(n);
    setState(() => _focusedIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (index < _focusNodes.length) {
        _focusNodes[index].requestFocus();
      }
    });
    return true;
  }

  void focusFirstGridTile() {
    void attempt(int n) {
      if (!mounted) return;
      if (focusGridIndex(0)) return;
      if (n < 15) {
        WidgetsBinding.instance.addPostFrameCallback((_) => attempt(n + 1));
      }
    }

    attempt(0);
  }

  void _moveGridFocus(int newIndex, int total) {
    if (newIndex < 0 || newIndex >= total) return;
    setState(() => _focusedIndex = newIndex);
    if (newIndex < _focusNodes.length) {
      _focusNodes[newIndex].requestFocus();
    }
  }

  KeyEventResult _gridKeyHandler(
    int index,
    List<AppMediaAggregate> items,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final total = items.length;
    final cols = _cols;
    final row = index ~/ cols;
    final col = index % cols;
    final k = event.logicalKey;

    if (_focusedIndex != index) {
      setState(() => _focusedIndex = index);
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (col > 0) _moveGridFocus(index - 1, total);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (col < cols - 1 && index + 1 < total) {
        _moveGridFocus(index + 1, total);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (row > 0) {
        _moveGridFocus(index - cols, total);
      } else {
        widget.sourcesNavFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (index + cols < total) {
        _moveGridFocus(index + cols, total);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      ref.read(homeBrowseFocusProvider.notifier).setSourcesGridFocus(
            mainTab: 1,
            gridIndex: index,
          );
      widget.onOpenItem(items[index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
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
        final n = items.length;
        _lastItemCount = n;
        _syncFocusNodes(n);
        if (_focusedIndex != null && _focusedIndex! >= n) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _focusedIndex = null);
          });
        }
        return LayoutBuilder(
          builder: (context, c) {
            const gap = 10.0;
            final pad = AppLayout.tvHorizontalInset;
            final w = c.maxWidth - pad * 2;
            final cellW = (w - gap * (_cols - 1)) / _cols;
            final posterH = cellW * 1.5;
            final cellH = posterH + 52;
            return GridView.builder(
              padding: EdgeInsets.fromLTRB(
                pad,
                8,
                pad,
                AppLayout.screenBottomInset + AppLayout.tvSectionVerticalGap,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _cols,
                mainAxisSpacing: gap,
                crossAxisSpacing: gap,
                childAspectRatio: cellW / cellH,
              ),
              itemCount: n,
              itemBuilder: (context, index) {
                final item = items[index];
                final m = item.media;
                final selected = _focusedIndex == index;
                return Focus(
                  focusNode: _focusNodes[index],
                  onFocusChange: (hasFocus) {
                    if (hasFocus) {
                      ref.read(homeBrowseFocusProvider.notifier).setSourcesGridFocus(
                            mainTab: 1,
                            gridIndex: index,
                          );
                      if (_focusedIndex == index) return;
                      setState(() => _focusedIndex = index);
                      return;
                    }
                    if (_focusedIndex != index) return;
                    setState(() => _focusedIndex = null);
                  },
                  onKeyEvent: (_, e) => _gridKeyHandler(index, items, e),
                  child: Material(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    elevation: selected ? 6 : 0,
                    shadowColor: Colors.black,
                    surfaceTintColor: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        ref.read(homeBrowseFocusProvider.notifier).setSourcesGridFocus(
                              mainTab: 1,
                              gridIndex: index,
                            );
                        widget.onOpenItem(item);
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: LibraryMediaPoster(
                              media: m,
                              files: item.files,
                              placeholderIconSize: 32,
                              progressStrokeWidth: 2,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: selected ? 13 : 12,
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
