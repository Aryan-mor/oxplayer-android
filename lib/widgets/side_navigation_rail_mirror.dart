import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/focus/dpad_navigator.dart';
import '../core/focus/focus_memory_tracker.dart';
import '../core/focus/input_mode_tracker.dart';
import '../core/navigation/navigation_tabs_mirror.dart';
import '../core/theme/app_theme.dart';

/// Reusable navigation rail item widget.
class NavigationRailItem extends StatelessWidget {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final bool isSelected;
  final bool isFocused;
  final bool isCollapsed;
  final VoidCallback onTap;
  final FocusNode focusNode;
  final bool autofocus;
  final double iconSize;
  final VoidCallback? onNavigateRight;

  const NavigationRailItem({
    super.key,
    required this.icon,
    this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.isFocused,
    this.isCollapsed = false,
    required this.onTap,
    required this.focusNode,
    this.autofocus = false,
    this.iconSize = 22,
    this.onNavigateRight,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey.isSelectKey) {
          onTap();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight && onNavigateRight != null) {
          onNavigateRight!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: () {
                if (isSelected && isFocused) return AppColors.onSurfacePrimary.withValues(alpha: 0.15);
                if (isSelected) return AppColors.onSurfacePrimary.withValues(alpha: 0.10);
                if (isFocused) return AppColors.onSurfacePrimary.withValues(alpha: 0.12);
                return null;
              }(),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.hardEdge,
            child: UnconstrainedBox(
              alignment: Alignment.centerLeft,
              constrainedAxis: Axis.vertical,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: SideNavigationRailState.expandedWidth - 24,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 17),
                  child: Row(
                    children: [
                      Icon(
                        isSelected && selectedIcon != null ? selectedIcon! : icon,
                        size: iconSize,
                        color: isSelected ? AppColors.onSurfacePrimary : AppColors.textMuted,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: AnimatedOpacity(
                          opacity: isCollapsed ? 0.0 : 1.0,
                          duration: const Duration(milliseconds: 150),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                              color: isSelected ? AppColors.onSurfacePrimary : AppColors.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Side navigation rail for TV and wide-screen layouts.
/// Mirrors Plezy's SideNavigationRail exactly.
class SideNavigationRailMirror extends StatefulWidget {
  final AppTabId selectedTab;
  final bool isSidebarFocused;
  final bool alwaysExpanded;
  final ValueChanged<AppTabId> onDestinationSelected;
  final VoidCallback? onNavigateToContent;

  const SideNavigationRailMirror({
    super.key,
    required this.selectedTab,
    this.isSidebarFocused = false,
    this.alwaysExpanded = false,
    required this.onDestinationSelected,
    this.onNavigateToContent,
  });

  @override
  State<SideNavigationRailMirror> createState() => SideNavigationRailState();
}

class SideNavigationRailState extends State<SideNavigationRailMirror> {
  bool _isHovered = false;
  bool _isTouchExpanded = false;
  Timer? _collapseTimer;

  static const double collapsedWidth = 80.0;
  static const double expandedWidth = 220.0;
  static const Duration _collapseDelay = Duration(milliseconds: 150);

  static const _kHome = 'home';
  static const _kSources = 'sources';
  static const _kMyOx = 'myOx';
  static const _kSettings = 'settings';

  late final FocusMemoryTracker _focusTracker;

  bool get _shouldExpand => widget.alwaysExpanded || _isHovered || _isTouchExpanded || widget.isSidebarFocused;

  String? get lastFocusedKey => _focusTracker.lastFocusedKey;

  @override
  void initState() {
    super.initState();
    _focusTracker = FocusMemoryTracker(
      onFocusChanged: () {
        if (mounted) setState(() {});
      },
      debugLabelPrefix: 'nav',
    );
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    _focusTracker.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SideNavigationRailMirror oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTab != widget.selectedTab) {
      _isTouchExpanded = false;
    }
  }

  void _onHoverEnter() {
    _collapseTimer?.cancel();
    _isTouchExpanded = false;
    if (!_isHovered) setState(() => _isHovered = true);
  }

  void _onHoverExit() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(_collapseDelay, () {
      if (mounted && _isHovered) setState(() => _isHovered = false);
    });
  }

  void focusActiveItem({String? targetKey}) {
    if (targetKey != null) {
      final node = _focusTracker.nodeFor(targetKey);
      if (node != null) {
        node.requestFocus();
        return;
      }
    }
    _focusTracker.restoreFocus(fallbackKey: _kHome);
  }

  List<String> _buildFocusOrder() {
    return [_kHome, _kSources, _kMyOx, _kSettings];
  }

  KeyEventResult _handleVerticalNavigation(FocusNode _, KeyEvent event, List<String> focusOrder) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isDown = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final isUp = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!isDown && !isUp) return KeyEventResult.ignored;

    final currentKey = _focusTracker.lastFocusedKey;
    if (currentKey == null) return KeyEventResult.ignored;

    final currentIndex = focusOrder.indexOf(currentKey);
    if (currentIndex == -1) return KeyEventResult.ignored;

    final nextIndex = isDown ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= focusOrder.length) return KeyEventResult.handled;

    final nextNode = _focusTracker.nodeFor(focusOrder[nextIndex]);
    if (nextNode == null) return KeyEventResult.ignored;

    nextNode.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final isCollapsed = !_shouldExpand;
    final focusOrder = _buildFocusOrder();

    return TapRegion(
      onTapOutside: (_) {
        if (_isTouchExpanded) setState(() => _isTouchExpanded = false);
      },
      child: MouseRegion(
        onEnter: (_) => _onHoverEnter(),
        onExit: (_) => _onHoverExit(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isCollapsed ? () => setState(() => _isTouchExpanded = true) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: isCollapsed ? collapsedWidth : expandedWidth,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(color: AppColors.surface),
            child: IgnorePointer(
              ignoring: isCollapsed,
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (node, event) => _handleVerticalNavigation(node, event, focusOrder),
                child: Column(
                  children: [
                    SizedBox(height: MediaQuery.of(context).padding.top + 16),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        clipBehavior: Clip.hardEdge,
                        children: [
                          _buildNavItem(
                            icon: Icons.home_outlined,
                            selectedIcon: Icons.home_rounded,
                            label: 'Home',
                            tabId: AppTabId.home,
                            focusKey: _kHome,
                            isCollapsed: isCollapsed,
                          ),
                          const SizedBox(height: 8),
                          _buildNavItem(
                            icon: Icons.hub_outlined,
                            selectedIcon: Icons.hub_rounded,
                            label: 'Sources',
                            tabId: AppTabId.sources,
                            focusKey: _kSources,
                            isCollapsed: isCollapsed,
                          ),
                          const SizedBox(height: 8),
                          _buildNavItem(
                            icon: Icons.account_circle_outlined,
                            selectedIcon: Icons.account_circle_rounded,
                            label: 'My OX',
                            tabId: AppTabId.myOx,
                            focusKey: _kMyOx,
                            isCollapsed: isCollapsed,
                          ),
                          const SizedBox(height: 8),
                          _buildNavItem(
                            icon: Icons.settings_outlined,
                            selectedIcon: Icons.settings_rounded,
                            label: 'Settings',
                            tabId: AppTabId.settings,
                            focusKey: _kSettings,
                            isCollapsed: isCollapsed,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    required AppTabId tabId,
    required String focusKey,
    required bool isCollapsed,
    bool autofocus = false,
  }) {
    return NavigationRailItem(
      icon: icon,
      selectedIcon: selectedIcon,
      label: label,
      isSelected: widget.selectedTab == tabId,
      isFocused: _focusTracker.isFocused(focusKey),
      isCollapsed: isCollapsed,
      onTap: () => widget.onDestinationSelected(tabId),
      focusNode: _focusTracker.get(focusKey),
      autofocus: autofocus,
      onNavigateRight: widget.onNavigateToContent,
    );
  }
}
