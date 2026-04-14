import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:oxplayer/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../i18n/strings.g.dart';

/// Navigation tab identifiers
enum NavigationTabId { discover, libraries, myTelegram, search, downloads, settings }

/// Represents a navigation tab with its configuration
class NavigationTab {
  final NavigationTabId id;
  final bool onlineOnly;
  final IconData icon;
  final String Function() getLabel;

  const NavigationTab({required this.id, required this.onlineOnly, required this.icon, required this.getLabel});

  NavigationDestination toDestination() {
    return NavigationDestination(icon: AppIcon(icon, fill: 1), selectedIcon: AppIcon(icon, fill: 1), label: getLabel());
  }

  /// Get the index for a tab ID in the visible tabs list
  static int indexFor(NavigationTabId id, {required bool isOffline}) {
    final tabs = getVisibleTabs(isOffline: isOffline);
    return tabs.indexWhere((tab) => tab.id == id);
  }

  /// Get tabs filtered by offline mode and feature availability
  static List<NavigationTab> getVisibleTabs({required bool isOffline}) {
    return allNavigationTabs.where((tab) {
      if (isOffline && tab.onlineOnly) return false;
      // TDLib is unavailable on web; hide this surface everywhere on web.
      if (tab.id == NavigationTabId.myTelegram && kIsWeb) return false;
      return true;
    }).toList();
  }

}

// Label getters (must be top-level for const constructor)
String _getHomeLabel() => t.common.home;
String _getLibrariesLabel() => t.navigation.libraries;
String _getMyTelegramLabel() => t.navigation.myTelegram;
String _getSearchLabel() => t.common.search;
String _getDownloadsLabel() => t.navigation.downloads;
String _getSettingsLabel() => t.common.settings;

/// All navigation tabs in display order
const allNavigationTabs = [
  NavigationTab(id: NavigationTabId.discover, onlineOnly: true, icon: Symbols.home_rounded, getLabel: _getHomeLabel),
  NavigationTab(
    id: NavigationTabId.libraries,
    onlineOnly: true,
    icon: Symbols.video_library_rounded,
    getLabel: _getLibrariesLabel,
  ),
  NavigationTab(
    id: NavigationTabId.myTelegram,
    // Like Downloads/Settings: keep visible when Plex/offline UI is limited so Telegram+OX flows stay reachable.
    onlineOnly: false,
    icon: Symbols.chat_rounded,
    getLabel: _getMyTelegramLabel,
  ),
  NavigationTab(id: NavigationTabId.search, onlineOnly: true, icon: Symbols.search_rounded, getLabel: _getSearchLabel),
  NavigationTab(
    id: NavigationTabId.downloads,
    onlineOnly: false,
    icon: Symbols.download_rounded,
    getLabel: _getDownloadsLabel,
  ),
  NavigationTab(
    id: NavigationTabId.settings,
    onlineOnly: false,
    icon: Symbols.settings_rounded,
    getLabel: _getSettingsLabel,
  ),
];
