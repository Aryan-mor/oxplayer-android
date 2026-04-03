import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';

/// D-Pad-navigable button with scale + glow + focus border animations.
///
/// Wrap any child in this to get the established TeleCima TV focus treatment.
/// The [autofocus] flag should be set to `true` on the primary action (Play).
class TVButton extends StatefulWidget {
  const TVButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.autofocus = false,
    this.focusNode,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    this.borderRadius = 10.0,
    this.onKeyEvent,
    this.onFocusChanged,
    /// When true, shows a persistent highlight border (e.g. active filter) even without focus.
    this.selected = false,
    /// When true, no border/background until focused (e.g. episode title in download rows).
    this.plainWhenUnfocused = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool enabled;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final bool selected;
  final bool plainWhenUnfocused;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;
  final ValueChanged<bool>? onFocusChanged;

  @override
  State<TVButton> createState() => _TVButtonState();
}

class _TVButtonState extends State<TVButton> {
  FocusNode? _internalFocusNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _internalFocusNode = FocusNode(debugLabel: 'TVButton');
    }
  }

  @override
  void dispose() {
    _internalFocusNode?.dispose();
    super.dispose();
  }

  bool _isCenterOrSelect(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.select) return true;
    final label = key.keyLabel.toLowerCase();
    if (label == 'center' || label == 'dpad center' || label == 'select') {
      return true;
    }
    // Android keyCode 23 (DPAD_CENTER) often appears on generic TV remotes.
    return key.keyId == 0x00100000017 || key.keyId == 23;
  }

  bool _isActivateKey(LogicalKeyboardKey key) {
    return _isCenterOrSelect(key) ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final custom = widget.onKeyEvent;
    if (custom != null) {
      final result = custom(node, event);
      if (result == KeyEventResult.handled) return result;
    }
    if (!widget.enabled) return KeyEventResult.ignored;
    if (event is KeyDownEvent && _isActivateKey(event.logicalKey)) {
      widget.onPressed?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final focusNode = widget.focusNode ?? _internalFocusNode!;
    final plain = widget.plainWhenUnfocused && !_focused && !widget.selected;
    return Focus(
      autofocus: widget.autofocus,
      focusNode: focusNode,
      onKeyEvent: _handleKey,
      onFocusChange: (focused) {
        if (!mounted) return;
        setState(() => _focused = focused);
        widget.onFocusChanged?.call(focused);
      },
      child: Transform.scale(
        scale: _focused ? 1.05 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: plain
                  ? Colors.transparent
                  : _focused
                      ? AppColors.highlight
                      : widget.selected
                          ? AppColors.highlight
                          : AppColors.border,
              width: plain
                  ? 0
                  : _focused
                      ? 3.0
                      : (widget.selected ? 2.0 : 1.0),
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: AppColors.highlight.withValues(alpha: 0.45),
                      blurRadius: 15,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
            color: plain
                ? Colors.transparent
                : _focused
                    ? AppColors.highlight.withValues(alpha: 0.15)
                    : widget.selected
                        ? AppColors.highlight.withValues(alpha: 0.12)
                        : AppColors.card,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              onTap: widget.enabled ? widget.onPressed : null,
              child: Padding(
                padding: widget.padding,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
