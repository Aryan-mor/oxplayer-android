import 'package:flutter/services.dart';

/// Extension on KeyEvent for common event type checks.
extension KeyEventActionable on KeyEvent {
  /// Whether this event should trigger an action (KeyDownEvent or KeyRepeatEvent).
  bool get isActionable => this is KeyDownEvent || this is KeyRepeatEvent;
}

/// Shared sets for keyboard key categories.
final _dpadDirectionKeys = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

final _selectKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
};

final _backKeys = {
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.goBack,
  LogicalKeyboardKey.browserBack,
  LogicalKeyboardKey.gameButtonB,
};

final _contextMenuKeys = {LogicalKeyboardKey.contextMenu, LogicalKeyboardKey.gameButtonX};

/// Extension methods for checking D-pad related keys.
extension DpadKeyExtension on LogicalKeyboardKey {
  bool get isDpadDirection => _dpadDirectionKeys.contains(this);
  bool get isSelectKey => _selectKeys.contains(this);
  bool get isBackKey => _backKeys.contains(this);
  bool get isContextMenuKey => _contextMenuKeys.contains(this);
  bool get isNavigationKey =>
      isDpadDirection || isSelectKey || isBackKey || isContextMenuKey || this == LogicalKeyboardKey.tab;
  bool get isLeftKey => this == LogicalKeyboardKey.arrowLeft;
  bool get isRightKey => this == LogicalKeyboardKey.arrowRight;
  bool get isUpKey => this == LogicalKeyboardKey.arrowUp;
  bool get isDownKey => this == LogicalKeyboardKey.arrowDown;
}

/// Base class for suppressing key-up events after a key category triggers an action.
class _KeyUpSuppressor {
  final bool Function(LogicalKeyboardKey) _keyMatcher;
  _KeyUpSuppressor(this._keyMatcher);
  bool _suppressed = false;

  void suppress() => _suppressed = true;
  void clearSuppression() => _suppressed = false;

  bool consumeIfSuppressed(KeyEvent event) {
    if (!_suppressed) return false;
    if (_keyMatcher(event.logicalKey)) {
      if (event is KeyUpEvent) _suppressed = false;
      return true;
    }
    return false;
  }
}

/// Global helper to suppress the next SELECT key-up event.
class SelectKeyUpSuppressor {
  static final _instance = _KeyUpSuppressor((k) => k.isSelectKey);
  static void suppressSelectUntilKeyUp() => _instance.suppress();
  static void clearSuppression() => _instance.clearSuppression();
  static bool consumeIfSuppressed(KeyEvent event) => _instance.consumeIfSuppressed(event);
}

/// Global helper to suppress the next BACK key-up event.
class BackKeyUpSuppressor {
  static final _instance = _KeyUpSuppressor((k) => k.isBackKey);
  static bool _closedViaBackKey = false;

  static void markClosedViaBackKey() {
    _closedViaBackKey = true;
  }

  static void suppressBackUntilKeyUp() {
    if (_closedViaBackKey) {
      _closedViaBackKey = false;
      return;
    }
    _instance.suppress();
  }

  static void clearSuppression() {
    _instance.clearSuppression();
    _closedViaBackKey = false;
  }

  static bool consumeIfSuppressed(KeyEvent event) => _instance.consumeIfSuppressed(event);
}

/// Tracks whether a back key is currently physically pressed.
class BackKeyPressTracker {
  static bool _isBackKeyDown = false;

  static bool get isBackKeyDown {
    if (_isBackKeyDown) return true;
    return HardwareKeyboard.instance.logicalKeysPressed.any((key) => key.isBackKey);
  }

  static bool handleKeyEvent(KeyEvent event) {
    if (event.logicalKey.isBackKey) {
      _isBackKeyDown = event is! KeyUpEvent;
    }
    return false;
  }
}
