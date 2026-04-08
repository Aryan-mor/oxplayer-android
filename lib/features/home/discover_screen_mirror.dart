import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/focus/dpad_navigator.dart';
import '../../core/focus/locked_hub_controller.dart';
import '../../models/app_media.dart';
import '../../providers.dart';
import '../../widgets/hub_section.dart';
import 'home_presentation_adapter.dart';
import 'main_screen_mirror.dart';

/// Mirrors Plezy's DiscoverScreen:
/// - CustomScrollView with SliverToBoxAdapter hub sections
/// - Locked-focus hub pattern (HubSection)
/// - Vertical D-pad traversal between hubs (_handleVerticalNavigation)
/// - Left-from-first-item → focusSidebar handoff
/// - Overlay gradient app bar (non-focusable title)
class DiscoverScreenMirror extends ConsumerStatefulWidget {
  const DiscoverScreenMirror({super.key});

  @override
  ConsumerState<DiscoverScreenMirror> createState() => _DiscoverScreenMirrorState();
}

class _DiscoverScreenMirrorState extends ConsumerState<DiscoverScreenMirror> {
  final ScrollController _scrollController = ScrollController();

  // One GlobalKey per hub section so we can call requestFocusFromMemory()
  final List<GlobalKey<HubSectionState>> _hubKeys = [
    GlobalKey<HubSectionState>(debugLabel: 'hub_0'),
    GlobalKey<HubSectionState>(debugLabel: 'hub_1'),
    GlobalKey<HubSectionState>(debugLabel: 'hub_2'),
  ];

  /// Index of the currently focused hub (-1 = none)
  int _focusedHubIndex = -1;

  @override
  void dispose() {
    HubFocusMemory.clear();
    _scrollController.dispose();
    super.dispose();
  }

  // ── vertical navigation ─────────────────────────────────────────────────

  /// Called by each HubSection's onVerticalNavigation.
  /// [isUp] = true means D-pad Up, false = D-pad Down.
  /// Returns true if the navigation was handled.
  bool _handleVerticalNavigation(int hubIndex, bool isUp) {
    final targetIndex = isUp ? hubIndex - 1 : hubIndex + 1;

    if (targetIndex < 0) {
      // At top hub pressing Up → nothing above (no app bar in this port)
      return false;
    }

    final hubCount = HomePresentationAdapter.sections.length;
    if (targetIndex >= hubCount) {
      // At bottom hub pressing Down → nothing below
      return false;
    }

    _focusedHubIndex = targetIndex;
    _hubKeys[targetIndex].currentState?.requestFocusFromMemory();
    return true;
  }

  void _navigateToSidebar() {
    MainScreenFocusScope.of(context)?.focusSidebar();
  }

  // ── item navigation ─────────────────────────────────────────────────────

  void _onItemTap(AppMediaAggregate item) {
    context.push('/item/${Uri.encodeComponent(item.media.id)}');
  }

  // ── build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CustomScrollView(
          controller: _scrollController,
          slivers: [
            // Top padding for the overlay app bar
            const SliverToBoxAdapter(child: SizedBox(height: 80)),

            // Hub sections
            for (var i = 0; i < HomePresentationAdapter.sections.length; i++) ...[
              SliverToBoxAdapter(
                child: _DiscoverHubSection(
                  hubKey: _hubKeys[i],
                  hubIndex: i,
                  section: HomePresentationAdapter.sections[i],
                  onVerticalNavigation: (isUp) => _handleVerticalNavigation(i, isUp),
                  onNavigateToSidebar: _navigateToSidebar,
                  onItemTap: _onItemTap,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 18)),
            ],

            // Bottom safe area
            SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
            ),
          ],
        ),

        // Overlay app bar (gradient, non-focusable)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _buildOverlayAppBar(context),
        ),
      ],
    );
  }

  Widget _buildOverlayAppBar(BuildContext context) {
    return IgnorePointer(
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).scaffoldBackgroundColor,
              Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: const SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'OXPlayer',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Individual hub section with async data loading.
class _DiscoverHubSection extends ConsumerWidget {
  const _DiscoverHubSection({
    required this.hubKey,
    required this.hubIndex,
    required this.section,
    required this.onVerticalNavigation,
    required this.onNavigateToSidebar,
    required this.onItemTap,
  });

  final GlobalKey<HubSectionState> hubKey;
  final int hubIndex;
  final HomeSectionVm section;
  final bool Function(bool isUp) onVerticalNavigation;
  final VoidCallback onNavigateToSidebar;
  final ValueChanged<AppMediaAggregate> onItemTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(libraryMediaByKindProvider(section.kind));

    return async.when(
      data: (items) {
        if (items.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              'No ${section.title}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          );
        }
        return HubSection(
          key: hubKey,
          hub: HubSectionData(
            hubKey: section.id,
            title: section.title,
            items: items,
          ),
          icon: _iconForSection(section.kind),
          onItemTap: onItemTap,
          onVerticalNavigation: onVerticalNavigation,
          onNavigateToSidebar: onNavigateToSidebar,
        );
      },
      loading: () => const SizedBox(
        height: 280,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Failed to load ${section.title}: $e',
            style: const TextStyle(color: Colors.redAccent)),
      ),
    );
  }

  IconData _iconForSection(String kind) {
    switch (kind) {
      case 'movie':
        return Icons.movie_rounded;
      case 'series':
        return Icons.tv_rounded;
      default:
        return Icons.local_movies_rounded;
    }
  }
}

