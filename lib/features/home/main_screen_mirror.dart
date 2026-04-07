import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/focus/dpad_navigator.dart';
import '../../core/focus/key_event_utils.dart';
import '../../core/navigation/navigation_tabs_mirror.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/side_navigation_rail_mirror.dart';
import 'discover_screen_mirror.dart';


/// Provides access to the main screen's focus control, so child screens
/// can call `MainScreenFocusScope.of(context)?.focusSidebar()`.
class MainScreenFocusScope extends InheritedWidget {
  final VoidCallback focusSidebar;
  final VoidCallback focusContent;
  final bool isSidebarFocused;

  const MainScreenFocusScope({
    super.key,
    required this.focusSidebar,
    required this.focusContent,
    required this.isSidebarFocused,
    required super.child,
  });

  static MainScreenFocusScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MainScreenFocusScope>();
  }

  @override
  bool updateShouldNotify(MainScreenFocusScope oldWidget) {
    return isSidebarFocused != oldWidget.isSidebarFocused;
  }
}

/// The main app shell: side nav rail + content area with IndexedStack.
/// Mirrors Plezy's MainScreen: sidebar focus scope, D-pad focus handoff,
/// Back key behaviour (content → sidebar → exit).
class MainScreenMirror extends StatefulWidget {
  const MainScreenMirror({super.key});

  @override
  State<MainScreenMirror> createState() => _MainScreenMirrorState();
}

class _MainScreenMirrorState extends State<MainScreenMirror> {
  AppTabId _currentTab = AppTabId.home;

  final GlobalKey<SideNavigationRailState> _sideNavKey = GlobalKey();

  final FocusScopeNode _sidebarFocusScope = FocusScopeNode(debugLabel: 'Sidebar');
  final FocusScopeNode _contentFocusScope = FocusScopeNode(debugLabel: 'Content');
  bool _isSidebarFocused = false;


  // ── tab screens ────────────────────────────────────────────────────────

  late final List<Widget> _screens = [
    const DiscoverScreenMirror(),
    // Sources — shown if available, else placeholder
    const _SourcesPlaceholder(),
    // MyOx
    const _MyOxPlaceholder(),
    // Settings
    const _SettingsPlaceholder(),
  ];


  int get _currentIndex {
    return AppTabId.values.indexOf(_currentTab).clamp(0, _screens.length - 1);
  }

  // ── focus helpers ───────────────────────────────────────────────────────

  void _focusSidebar() {
    if (_isSidebarFocused) return;
    // Capture the currently focused sidebar item before the scope switch clears it
    final targetKey = _sideNavKey.currentState?.lastFocusedKey;
    setState(() => _isSidebarFocused = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sidebarFocusScope.requestFocus();
      _sideNavKey.currentState?.focusActiveItem(targetKey: targetKey);
    });
  }

  void _focusContent() {
    if (!_isSidebarFocused) return;
    setState(() => _isSidebarFocused = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _contentFocusScope.requestFocus();
    });
  }

  @override
  void initState() {
    super.initState();
    // Start with content focused (sidebar collapsed by default)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _contentFocusScope.requestFocus();
    });
  }

  @override
  void dispose() {
    _sidebarFocusScope.dispose();
    _contentFocusScope.dispose();
    super.dispose();
  }

  void _handleTabSelected(AppTabId tab) {
    if (_currentTab == tab) {
      _focusContent();
      return;
    }
    setState(() => _currentTab = tab);
    _focusContent();
  }

  // ── back key handling ───────────────────────────────────────────────────

  KeyEventResult _handleBackKey(KeyEvent event) {
    if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;

    // Check for suppression first
    if (BackKeyUpSuppressor.consumeIfSuppressed(event)) return KeyEventResult.handled;

    if (event is KeyDownEvent || event is KeyRepeatEvent) return KeyEventResult.handled;

    if (event is KeyUpEvent) {
      if (_isSidebarFocused) {
        // Back from sidebar: exit app
        _exitApp();
      } else {
        // Back from content: go to sidebar
        _focusSidebar();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _exitApp() {
    if (Platform.isAndroid) {
      SystemNavigator.pop();
    } else {
      // On other platforms, just go back normally
    }
  }

  // ── build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 600;

    return MainScreenFocusScope(
      focusSidebar: _focusSidebar,
      focusContent: _focusContent,
      isSidebarFocused: _isSidebarFocused,
      child: Focus(
        onKeyEvent: (_, event) => _handleBackKey(event),
        child: Scaffold(
          backgroundColor: AppColors.bg,
          body: isWide ? _buildWideLayout() : _buildNarrowLayout(),
        ),
      ),
    );
  }

  Widget _buildWideLayout() {
    return Row(
      children: [
        // Sidebar
        FocusScope(
          node: _sidebarFocusScope,
          child: SideNavigationRailMirror(
            key: _sideNavKey,
            selectedTab: _currentTab,
            isSidebarFocused: _isSidebarFocused,
            onDestinationSelected: _handleTabSelected,
            onNavigateToContent: _focusContent,
          ),
        ),

        // Content area
        Expanded(
          child: FocusScope(
            node: _contentFocusScope,
            child: _buildContentStack(),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout() {
    return Column(
      children: [
        Expanded(
          child: _buildContentStack(),
        ),
        NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (i) => _handleTabSelected(AppTabId.values[i]),
          destinations: allAppNavigationTabs.map((t) => t.toDestination()).toList(),
        ),
      ],
    );
  }

  Widget _buildContentStack() {
    return IndexedStack(
      index: _currentIndex,
      children: _screens.asMap().entries.map((entry) {
        return TickerMode(
          enabled: entry.key == _currentIndex,
          child: entry.value,
        );
      }).toList(),
    );
  }
}

/// Placeholder screens for tabs not yet migrated.
class _SourcesPlaceholder extends StatelessWidget {
  const _SourcesPlaceholder();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Sources', style: TextStyle(color: Colors.white, fontSize: 24))),
    );
  }
}

class _MyOxPlaceholder extends StatelessWidget {
  const _MyOxPlaceholder();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('My OX', style: TextStyle(color: Colors.white, fontSize: 24))),
    );
  }
}

class _SettingsPlaceholder extends StatelessWidget {
  const _SettingsPlaceholder();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Settings', style: TextStyle(color: Colors.white, fontSize: 24))),
    );
  }
}
