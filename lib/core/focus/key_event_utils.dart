import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dpad_navigator.dart';

/// Coordinates back key handling to prevent double-handling across frames.
class BackKeyCoordinator {
  static bool _handledThisFrame = false;
  static bool _clearScheduled = false;

  static void markHandled() {
    _handledThisFrame = true;
    if (_clearScheduled) return;
    _clearScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handledThisFrame = false;
      _clearScheduled = false;
    });
  }

  static bool consumeIfHandled() {
    if (_handledThisFrame) {
      _handledThisFrame = false;
      return true;
    }
    return false;
  }
}

/// Handle a BACK key press by running [onBack] on key up.
///
/// Consumes KeyDown/KeyRepeat to avoid duplicate actions from key repeat.
KeyEventResult handleBackKeyAction(KeyEvent event, VoidCallback onBack) {
  if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;

  // Check if this BACK event should be suppressed (e.g., after modal closed)
  if (BackKeyUpSuppressor.consumeIfSuppressed(event)) {
    return KeyEventResult.handled;
  }

  if (event is KeyUpEvent) {
    BackKeyCoordinator.markHandled();
    BackKeyUpSuppressor.markClosedViaBackKey();
    onBack();
    return KeyEventResult.handled;
  }
  if (event is KeyDownEvent || event is KeyRepeatEvent) {
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// Handle back key navigation by popping the current route.
KeyEventResult handleBackKeyNavigation<T>(BuildContext context, KeyEvent event, {T? result}) {
  if (!Navigator.canPop(context)) return KeyEventResult.ignored;
  return handleBackKeyAction(event, () => Navigator.pop(context, result));
}

/// Creates a [FocusOnKeyEventCallback] that dispatches d-pad / arrow keys to
/// the provided directional callbacks.
FocusOnKeyEventCallback dpadKeyHandler({
  VoidCallback? onUp,
  VoidCallback? onDown,
  VoidCallback? onLeft,
  VoidCallback? onRight,
  VoidCallback? onSelect,
}) {
  return (FocusNode _, KeyEvent event) {
    if (!event.isActionable) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key.isUpKey && onUp != null) {
      onUp();
      return KeyEventResult.handled;
    }
    if (key.isDownKey && onDown != null) {
      onDown();
      return KeyEventResult.handled;
    }
    if (key.isLeftKey && onLeft != null) {
      onLeft();
      return KeyEventResult.handled;
    }
    if (key.isRightKey && onRight != null) {
      onRight();
      return KeyEventResult.handled;
    }
    if (key.isSelectKey && onSelect != null) {
      onSelect();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  };
}

/// Navigator observer that automatically suppresses stray back KeyUp events
/// after any route pop caused by a back key press.
class BackKeySuppressorObserver extends NavigatorObserver {
  @override
  void didPop(Route route, Route? previousRoute) {
    if (BackKeyPressTracker.isBackKeyDown) {
      BackKeyUpSuppressor.suppressBackUntilKeyUp();
    }
  }
}
