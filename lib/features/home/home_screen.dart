import 'package:flutter/material.dart';

import 'main_screen_mirror.dart';

/// Entry point for the home route ('/').
///
/// Delegates entirely to [MainScreenMirror] which implements the Plezy-style
/// shell (SideNavigationRailMirror + content IndexedStack + D-pad focus pipeline).
///
/// The old hybrid SideMenu + _HomeBrowseTab layout has been removed.
/// Focus is now managed by [MainScreenFocusScope] / [SideNavigationRailMirror].
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const MainScreenMirror();
  }
}
