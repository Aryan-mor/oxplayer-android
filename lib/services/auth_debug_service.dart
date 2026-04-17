import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

enum AuthDebugLevel { info, success, error }

enum LogType {
  other,
  auth,
  backend,
  tdlib,
  telegramThumbnail,
  locator,
  playMedia,
  cast,
}

extension LogTypePresentation on LogType {
  String get label => switch (this) {
    LogType.other => 'Other',
    LogType.auth => 'Auth',
    LogType.backend => 'Backend',
    LogType.tdlib => 'TDLib',
    LogType.telegramThumbnail => 'Telegram Thumbnail',
    LogType.locator => 'Locator',
    LogType.playMedia => 'Play Media',
    LogType.cast => 'Cast',
  };
}

enum AuthDebugStatusKey {
  telegramSessionDetected,
  telegramAuthorizationStarted,
  telegramAuthenticated,
  initDataFetched,
  backendRequestSent,
  backendAuthenticated,
  backendSessionStored,
}

class AuthDebugEntry {
  const AuthDebugEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.type,
  });

  final DateTime timestamp;
  final AuthDebugLevel level;
  final String message;
  final LogType type;
}

class AuthDebugStatusItem {
  const AuthDebugStatusItem({
    required this.key,
    required this.label,
    required this.completed,
  });

  final AuthDebugStatusKey key;
  final String label;
  final bool completed;

  AuthDebugStatusItem copyWith({bool? completed}) {
    return AuthDebugStatusItem(
      key: key,
      label: label,
      completed: completed ?? this.completed,
    );
  }
}

class AuthDebugService extends ChangeNotifier {
  AuthDebugService._();

  static final AuthDebugService instance = AuthDebugService._();
  static const int _maxEntries = 500;

  final ListQueue<AuthDebugEntry> _entries = ListQueue<AuthDebugEntry>();
  final Map<String, String> _lastValuesByKey = <String, String>{};
  bool _notifyScheduled = false;
  bool _debugLoggingEnabled = false;
  final Map<AuthDebugStatusKey, AuthDebugStatusItem> _statuses = {
    AuthDebugStatusKey.telegramSessionDetected: const AuthDebugStatusItem(
      key: AuthDebugStatusKey.telegramSessionDetected,
      label: 'Telegram session detected',
      completed: false,
    ),
    AuthDebugStatusKey.telegramAuthorizationStarted: const AuthDebugStatusItem(
      key: AuthDebugStatusKey.telegramAuthorizationStarted,
      label: 'Telegram authorization started',
      completed: false,
    ),
    AuthDebugStatusKey.telegramAuthenticated: const AuthDebugStatusItem(
      key: AuthDebugStatusKey.telegramAuthenticated,
      label: 'Telegram authenticated',
      completed: false,
    ),
    AuthDebugStatusKey.initDataFetched: const AuthDebugStatusItem(
      key: AuthDebugStatusKey.initDataFetched,
      label: 'Telegram initData fetched',
      completed: false,
    ),
    AuthDebugStatusKey.backendRequestSent: const AuthDebugStatusItem(
      key: AuthDebugStatusKey.backendRequestSent,
      label: 'Backend auth request sent',
      completed: false,
    ),
    AuthDebugStatusKey.backendAuthenticated: const AuthDebugStatusItem(
      key: AuthDebugStatusKey.backendAuthenticated,
      label: 'Backend authenticated',
      completed: false,
    ),
    AuthDebugStatusKey.backendSessionStored: const AuthDebugStatusItem(
      key: AuthDebugStatusKey.backendSessionStored,
      label: 'Backend session stored',
      completed: false,
    ),
  };

  bool get isEnabled => _debugLoggingEnabled;

  /// Sync with Settings → Debug Logging. When disabled, clears buffered entries and hides the debug UI.
  void applyDebugLoggingSetting(bool enabled) {
    if (_debugLoggingEnabled == enabled) return;
    _debugLoggingEnabled = enabled;
    if (!enabled) {
      _entries.clear();
      _lastValuesByKey.clear();
      for (final key in AuthDebugStatusKey.values) {
        _statuses[key] = _statuses[key]!.copyWith(completed: false);
      }
    }
    _scheduleNotify();
  }

  List<AuthDebugEntry> get entries => _entries.toList().reversed.toList(growable: false);

  List<AuthDebugEntry> entriesForType(LogType? type) {
    final allEntries = entries;
    if (type == null) return allEntries;
    return allEntries.where((entry) => entry.type == type).toList(growable: false);
  }

  List<AuthDebugStatusItem> get statuses => AuthDebugStatusKey.values
      .map((key) => _statuses[key]!)
      .toList(growable: false);

  void clearEntries({LogType? type}) {
    if (!isEnabled) return;
    if (type == null) {
      _entries.clear();
      _lastValuesByKey.clear();
      _scheduleNotify();
      return;
    }

    final retainedEntries = _entries.where((entry) => entry.type != type).toList(growable: false);
    _entries
      ..clear()
      ..addAll(retainedEntries);
    _lastValuesByKey.removeWhere((key, _) => key.startsWith('${type.name}:'));
    _scheduleNotify();
  }

  String formattedEntriesText({LogType? type}) {
    final filteredEntries = entriesForType(type);
    if (filteredEntries.isEmpty) {
      final label = type?.label ?? 'All';
      return 'No debug logs for $label.';
    }

    return filteredEntries.map((entry) {
      final time =
          '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}';
      return '[$time] [${entry.type.label}] ${entry.message}';
    }).join('\n');
  }

  void reset() {
    if (!isEnabled) return;
    clearEntries();
    for (final key in AuthDebugStatusKey.values) {
      _statuses[key] = _statuses[key]!.copyWith(completed: false);
    }
    _scheduleNotify();
  }

  void logInfo(String message, {AuthDebugStatusKey? completeStatus, LogType? type}) {
    _addEntry(AuthDebugLevel.info, message, completeStatus: completeStatus, type: type);
  }

  void logSuccess(String message, {AuthDebugStatusKey? completeStatus, LogType? type}) {
    _addEntry(AuthDebugLevel.success, message, completeStatus: completeStatus, type: type);
  }

  void logError(String message, {LogType? type}) {
    _addEntry(AuthDebugLevel.error, message, type: type);
  }

  void setStatus(AuthDebugStatusKey key, bool completed) {
    if (!isEnabled) return;
    _statuses[key] = _statuses[key]!.copyWith(completed: completed);
    _scheduleNotify();
  }

  void logDedup(String key, AuthDebugLevel level, String message, {AuthDebugStatusKey? completeStatus, LogType? type}) {
    if (!isEnabled) return;
    final normalizedType = type ?? LogType.other;
    final scopedKey = '${normalizedType.name}:$key';
    if (_lastValuesByKey[scopedKey] == message) return;
    _lastValuesByKey[scopedKey] = message;
    _addEntry(level, message, completeStatus: completeStatus, type: normalizedType);
  }

  void _addEntry(AuthDebugLevel level, String message, {AuthDebugStatusKey? completeStatus, LogType? type}) {
    if (!isEnabled) return;
    if (completeStatus != null) {
      _statuses[completeStatus] = _statuses[completeStatus]!.copyWith(completed: true);
    }
    final normalizedType = type ?? LogType.other;
    _entries.add(
      AuthDebugEntry(
        timestamp: DateTime.now(),
        level: level,
        message: message,
        type: normalizedType,
      ),
    );
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (hasListeners) {
        notifyListeners();
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}

void debugLogInfo(String message, {AuthDebugStatusKey? completeStatus, LogType? type}) {
  AuthDebugService.instance.logInfo(message, completeStatus: completeStatus, type: type);
}

void debugLogSuccess(String message, {AuthDebugStatusKey? completeStatus, LogType? type}) {
  AuthDebugService.instance.logSuccess(message, completeStatus: completeStatus, type: type);
}

void debugLogError(String message, {LogType? type}) {
  AuthDebugService.instance.logError(message, type: type);
}

void authDebugSetStatus(AuthDebugStatusKey key, bool completed) {
  AuthDebugService.instance.setStatus(key, completed);
}

void debugLogDedup(String key, AuthDebugLevel level, String message, {AuthDebugStatusKey? completeStatus, LogType? type}) {
  AuthDebugService.instance.logDedup(key, level, message, completeStatus: completeStatus, type: type);
}

void authDebugInfo(String message, {AuthDebugStatusKey? completeStatus}) {
  debugLogInfo(message, completeStatus: completeStatus, type: LogType.auth);
}

void authDebugSuccess(String message, {AuthDebugStatusKey? completeStatus}) {
  debugLogSuccess(message, completeStatus: completeStatus, type: LogType.auth);
}

void authDebugError(String message) {
  debugLogError(message, type: LogType.auth);
}

void authDebugDedup(String key, AuthDebugLevel level, String message, {AuthDebugStatusKey? completeStatus}) {
  debugLogDedup(key, level, message, completeStatus: completeStatus, type: LogType.auth);
}

void playMediaDebugInfo(String message) {
  debugLogInfo(message, type: LogType.playMedia);
}

void playMediaDebugSuccess(String message) {
  debugLogSuccess(message, type: LogType.playMedia);
}

void playMediaDebugError(String message) {
  debugLogError(message, type: LogType.playMedia);
}

void locatorDebugInfo(String message) {
  debugLogInfo(message, type: LogType.locator);
}

void locatorDebugSuccess(String message) {
  debugLogSuccess(message, type: LogType.locator);
}

void locatorDebugError(String message) {
  debugLogError(message, type: LogType.locator);
}

void castDebugInfo(String message) {
  debugLogInfo(message, type: LogType.cast);
}

void castDebugSuccess(String message) {
  debugLogSuccess(message, type: LogType.cast);
}

void castDebugError(String message) {
  debugLogError(message, type: LogType.cast);
}

void castDebugWarning(String message) {
  debugLogError(message, type: LogType.cast); // Use error level for warnings since there's no warning level
}
