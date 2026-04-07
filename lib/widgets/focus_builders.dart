import 'package:flutter/material.dart';

import '../core/focus/focus_theme.dart';
import '../core/focus/input_mode_tracker.dart';

/// Shared builders for focusable widgets to reduce code duplication.
class FocusBuilders {
  /// Builds a locked wrapper (no Focus widget) with scale and border decoration.
  /// Used by HubSection where focus is managed at a higher level.
  static Widget buildLockedFocusWrapper({
    required BuildContext context,
    required bool isFocused,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    double borderRadius = FocusTheme.defaultBorderRadius,
    required Widget child,
  }) {
    final isKeyboardMode = InputModeTracker.isKeyboardMode(context);

    // In touch mode, no item ever shows focus effects
    if (!isKeyboardMode) {
      return (onTap != null || onLongPress != null)
          ? GestureDetector(onTap: onTap, onLongPress: onLongPress, child: child)
          : child;
    }

    final duration = FocusTheme.getAnimationDuration(context);
    final showFocus = isFocused && isKeyboardMode;

    final focusedWidget = AnimatedScale(
      scale: showFocus ? FocusTheme.focusScale : 1.0,
      duration: duration,
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        decoration: FocusTheme.focusDecoration(context, isFocused: showFocus, borderRadius: borderRadius),
        child: child,
      ),
    );

    return (onTap != null || onLongPress != null)
        ? GestureDetector(onTap: onTap, onLongPress: onLongPress, child: focusedWidget)
        : focusedWidget;
  }
}
