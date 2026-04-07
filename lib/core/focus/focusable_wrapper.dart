import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dpad_navigator.dart';
import 'focus_theme.dart';
import 'input_mode_tracker.dart';
import 'key_event_utils.dart';


class FocusableWrapper extends StatefulWidget {
  const FocusableWrapper({
    super.key,
    required this.child,
    this.onSelect,
    this.onLongPress,
    this.onFocusChange,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateLeft,
    this.onNavigateRight,
    this.onBack,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = 10,
    this.autoScroll = true,
    this.scrollAlignment = 0.5,
    this.useComfortableZone = false,
    this.semanticLabel,
    this.canRequestFocus = true,
    this.onKeyEvent,
    this.enableLongPress = false,
    this.longPressDuration = const Duration(milliseconds: 500),
    this.disableScale = false,
    this.descendantsAreFocusable = true,
  });

  final Widget child;
  final VoidCallback? onSelect;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFocusChange;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onNavigateLeft;
  final VoidCallback? onNavigateRight;
  final VoidCallback? onBack;
  final bool autofocus;
  final FocusNode? focusNode;
  final double borderRadius;
  final bool autoScroll;
  final double scrollAlignment;
  final bool useComfortableZone;
  final String? semanticLabel;
  final bool canRequestFocus;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;
  final bool enableLongPress;
  final Duration longPressDuration;
  final bool disableScale;
  final bool descendantsAreFocusable;

  @override
  State<FocusableWrapper> createState() => _FocusableWrapperState();
}

class _FocusableWrapperState extends State<FocusableWrapper> with SingleTickerProviderStateMixin {
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _isFocused = false;
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  static const double _focusDecorationPadding = 8.0;
  Timer? _longPressTimer;
  bool _selectDown = false;

  @override
  void initState() {
    super.initState();
    _initFocusNode();
    _animationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
    _scaleAnimation = Tween<double>(
      begin: 1,
      end: FocusTheme.focusScale,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOutCubic));
  }

  void _initFocusNode() {
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
      _ownsFocusNode = false;
      return;
    }
    _focusNode = FocusNode(canRequestFocus: widget.canRequestFocus);
    _ownsFocusNode = true;
  }

  @override
  void didUpdateWidget(covariant FocusableWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      if (_ownsFocusNode) _focusNode.dispose();
      _initFocusNode();
    }
    if (widget.canRequestFocus != oldWidget.canRequestFocus) {
      _focusNode.canRequestFocus = widget.canRequestFocus;
    }
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _animationController.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChanged(bool hasFocus) {
    if (_isFocused == hasFocus) return;
    setState(() => _isFocused = hasFocus);
    if (hasFocus) {
      _animationController.forward();
      if (widget.autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focusNode.hasFocus) return;
          final scrollable = Scrollable.maybeOf(context);
          if (scrollable == null) return;
          final viewport = scrollable.context.findRenderObject() as RenderBox?;
          final itemBox = context.findRenderObject() as RenderBox?;
          if (viewport == null || itemBox == null) return;
          final itemPosition = itemBox.localToGlobal(Offset.zero, ancestor: viewport);
          final viewportHeight = viewport.size.height;
          final itemHeight = itemBox.size.height;
          final itemCenter = itemPosition.dy + itemHeight / 2;
          if (widget.useComfortableZone) {
            final top = viewportHeight * 0.2;
            final bottom = viewportHeight * 0.8;
            final itemTop = itemPosition.dy - _focusDecorationPadding;
            final itemBottom = itemPosition.dy + itemHeight + _focusDecorationPadding;
            if (itemTop >= top && itemBottom <= bottom) return;
          }
          final targetY = viewportHeight * widget.scrollAlignment;
          final delta = itemCenter - targetY;
          final position = scrollable.position;
          final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
          position.animateTo(
            target.toDouble(),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
          );
        });
      }
    } else {
      _animationController.reverse();
      _longPressTimer?.cancel();
      _selectDown = false;
    }
    widget.onFocusChange?.call(hasFocus);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (SelectKeyUpSuppressor.consumeIfSuppressed(event)) return KeyEventResult.handled;
    final custom = widget.onKeyEvent?.call(node, event);
    if (custom == KeyEventResult.handled) return KeyEventResult.handled;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      if (!widget.enableLongPress) {
        if (event is KeyDownEvent) widget.onSelect?.call();
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent && !_selectDown) {
        _selectDown = true;
        _longPressTimer?.cancel();
        _longPressTimer = Timer(widget.longPressDuration, () {
          if (mounted && _selectDown) widget.onLongPress?.call();
        });
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        final wasActive = _longPressTimer?.isActive ?? false;
        _longPressTimer?.cancel();
        if (wasActive && _selectDown) widget.onSelect?.call();
        _selectDown = false;
        return KeyEventResult.handled;
      }
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowUp && widget.onNavigateUp != null) {
      widget.onNavigateUp!.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && widget.onNavigateDown != null) {
      widget.onNavigateDown!.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && widget.onNavigateLeft != null) {
      widget.onNavigateLeft!.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight && widget.onNavigateRight != null) {
      widget.onNavigateRight!.call();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) && widget.onBack != null) {
      widget.onBack!.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final duration = FocusTheme.getAnimationDuration(context);
    if (_animationController.duration != duration) {
      _animationController.duration = duration;
    }
    final showFocus = _isFocused && InputModeTracker.isKeyboardMode(context);
    Widget result = Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      descendantsAreFocusable: widget.descendantsAreFocusable,
      onFocusChange: _handleFocusChanged,
      onKeyEvent: _onKey,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: showFocus && !widget.disableScale ? _scaleAnimation.value : 1,
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              decoration: FocusTheme.focusDecoration(
                context,
                isFocused: showFocus,
                borderRadius: widget.borderRadius,
              ),
              child: widget.child,
            ),
          );
        },
      ),
    );
    if (widget.semanticLabel != null) {
      result = Semantics(label: widget.semanticLabel, button: widget.onSelect != null, child: result);
    }
    return result;
  }
}
