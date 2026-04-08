import 'package:flutter/material.dart';

import '../core/focus/focus_theme.dart';
import '../core/focus/focusable_wrapper.dart';
import '../core/focus/input_mode_tracker.dart';

/// A focusable button wrapper for D-pad navigation on TV.
///
/// Wraps any button widget with [FocusableWrapper] and adds a white overlay
/// + contrasting border when focused. Tracks focus state internally so callers
/// don't need manual state management.
///
/// ```dart
/// OxplayerButton(
///   autofocus: true,
///   onPressed: _doSomething,
///   child: FilledButton.icon(
///     onPressed: _doSomething,
///     icon: Icon(Symbols.add_rounded),
///     label: Text('Create'),
///   ),
/// )
/// ```
class OxplayerButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Navigation callbacks for explicit focus control (e.g. horizontal button rows).
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateRight;
  final VoidCallback? onBack;

  /// Whether to scroll the widget into view when focused.
  final bool autoScroll;

  /// Whether to use background color instead of border for focus indicator.
  final bool useBackgroundFocus;

  /// Whether the button is currently selected (shows accent style).
  final bool selected;

  /// Optional inner padding for the button content.
  final EdgeInsetsGeometry? padding;

  /// Optional border radius override (defaults to 100 = pill shape).
  final double? borderRadius;

  const OxplayerButton({
    super.key,
    required this.child,
    this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onBack,
    this.autoScroll = true,
    this.useBackgroundFocus = false,
    this.selected = false,
    this.padding,
    this.borderRadius,
  });

  @override
  State<OxplayerButton> createState() => _OxplayerButtonState();
}

class _OxplayerButtonState extends State<OxplayerButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final isKeyboard = InputModeTracker.isKeyboardMode(context);
    final showFocus = _isFocused && isKeyboard;
    final duration = FocusTheme.getAnimationDuration(context);
    // In dpad mode: focused = full opacity, unfocused = dimmed
    final opacity = isKeyboard && !_isFocused ? 0.6 : 1.0;

    return FocusableWrapper(
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      disableScale: true,
      borderRadius: widget.borderRadius ?? 100,
      useBackgroundFocus: widget.useBackgroundFocus || widget.selected,
      descendantsAreFocusable: false,
      onFocusChange: (f) => setState(() => _isFocused = f),
      autoScroll: widget.autoScroll,
      onSelect: widget.onPressed,
      onNavigateUp: widget.onNavigateUp,
      onNavigateDown: widget.onNavigateDown,
      onNavigateLeft: widget.onNavigateLeft,
      onNavigateRight: widget.onNavigateRight,
      onBack: widget.onBack,
      child: AnimatedOpacity(
        opacity: showFocus ? 1.0 : (widget.selected ? 1.0 : opacity),
        duration: duration,
        child: widget.padding != null
            ? Padding(padding: widget.padding!, child: widget.child)
            : widget.child,
      ),
    );
  }
}


