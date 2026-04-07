import 'package:flutter/material.dart';

/// Navigation tab identifiers for OXPlayer.
enum AppTabId { home, sources, myOx, settings }

/// Represents a navigation tab with its configuration.
class AppNavigationTab {
  final AppTabId id;
  final IconData icon;
  final IconData? selectedIcon;
  final String Function() getLabel;

  const AppNavigationTab({
    required this.id,
    required this.icon,
    this.selectedIcon,
    required this.getLabel,
  });

  NavigationDestination toDestination() {
    return NavigationDestination(
      icon: Icon(icon),
      selectedIcon: Icon(selectedIcon ?? icon),
      label: getLabel(),
    );
  }
}

String _getHomeLabel() => 'Home';
String _getSourcesLabel() => 'Sources';
String _getMyOxLabel() => 'My OX';
String _getSettingsLabel() => 'Settings';

const allAppNavigationTabs = [
  AppNavigationTab(
    id: AppTabId.home,
    icon: Icons.home_outlined,
    selectedIcon: Icons.home_rounded,
    getLabel: _getHomeLabel,
  ),
  AppNavigationTab(
    id: AppTabId.sources,
    icon: Icons.hub_outlined,
    selectedIcon: Icons.hub_rounded,
    getLabel: _getSourcesLabel,
  ),
  AppNavigationTab(
    id: AppTabId.myOx,
    icon: Icons.account_circle_outlined,
    selectedIcon: Icons.account_circle_rounded,
    getLabel: _getMyOxLabel,
  ),
  AppNavigationTab(
    id: AppTabId.settings,
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
    getLabel: _getSettingsLabel,
  ),
];

