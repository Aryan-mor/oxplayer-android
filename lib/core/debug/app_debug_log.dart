import 'package:flutter/foundation.dart';

/// Categories map to tabs in the debug log dialog (except [all]).
enum AppDebugLogCategory {
  membership,
  tdlib,
  api,
  download,
  sync,
  locator,
  app,
  playback,
  stream,
  general,
}

extension AppDebugLogCategoryLabel on AppDebugLogCategory {
  String get tabLabel => switch (this) {
        AppDebugLogCategory.membership => 'Membership',
        AppDebugLogCategory.tdlib => 'TDLib',
        AppDebugLogCategory.api => 'API',
        AppDebugLogCategory.download => 'Download',
        AppDebugLogCategory.sync => 'Sync',
        AppDebugLogCategory.locator => 'Locator',
        AppDebugLogCategory.app => 'App',
        AppDebugLogCategory.playback => 'Playback',
        AppDebugLogCategory.stream => 'Stream',
        AppDebugLogCategory.general => 'Other',
      };
}

class _LogEntry {
  _LogEntry(this.line, this.category);
  final String line;
  final AppDebugLogCategory category;
}

/// In-memory ring buffer for debug builds (Oxplayer diagnostics).
class AppDebugLog extends ChangeNotifier {
  AppDebugLog._();
  static final AppDebugLog instance = AppDebugLog._();

  static const int maxLines = 3000;

  /// Tab order after **All** (index 0).
  static const List<AppDebugLogCategory> tabOrder = [
    AppDebugLogCategory.membership,
    AppDebugLogCategory.tdlib,
    AppDebugLogCategory.api,
    AppDebugLogCategory.download,
    AppDebugLogCategory.sync,
    AppDebugLogCategory.locator,
    AppDebugLogCategory.app,
    AppDebugLogCategory.playback,
    AppDebugLogCategory.stream,
    AppDebugLogCategory.general,
  ];

  final List<_LogEntry> _entries = <_LogEntry>[];
  bool _releaseLoggingEnabled = false;

  bool get isEnabled => kDebugMode || _releaseLoggingEnabled;

  void setReleaseLoggingEnabled(bool enabled) {
    if (_releaseLoggingEnabled == enabled) return;
    _releaseLoggingEnabled = enabled;
    notifyListeners();
  }

  /// Append a line (no-op in release builds).
  void log(
    String message, {
    AppDebugLogCategory category = AppDebugLogCategory.general,
  }) {
    if (!isEnabled) return;
    final line = message;
    _entries.add(_LogEntry(line, category));
    debugPrint('[${category.name}] $line');
    while (_entries.length > maxLines) {
      _entries.removeAt(0);
    }
    notifyListeners();
  }

  /// Every line, chronological (tab **All**).
  String get fullText => _entries.map((e) => e.line).join('\n');

  String textForCategory(AppDebugLogCategory category) => _entries
      .where((e) => e.category == category)
      .map((e) => e.line)
      .join('\n');

  int countIn(AppDebugLogCategory category) =>
      _entries.where((e) => e.category == category).length;

  int get totalCount => _entries.length;

  void clear() {
    if (!isEnabled) return;
    _entries.clear();
    notifyListeners();
  }
}
