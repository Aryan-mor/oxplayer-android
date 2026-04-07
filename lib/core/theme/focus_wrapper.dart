import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

class FocusWrapper extends StatefulWidget {
  const FocusWrapper({
    super.key,
    required this.focusNode,
    required this.child,
    this.autofocus = false,
    this.onKeyEvent,
    this.onFocusChanged,
    this.borderRadius = 10,
    this.disableScale = false,
  });

  final FocusNode focusNode;
  final Widget child;
  final bool autofocus;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;
  final ValueChanged<bool>? onFocusChanged;
  final double borderRadius;
  final bool disableScale;

  @override
  State<FocusWrapper> createState() => _FocusWrapperState();
}

class _FocusWrapperState extends State<FocusWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  late final Animation<double> _scale = Tween<double>(begin: 1, end: 1.02)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  bool _focused = false;
  bool _isKeyboardMode = false;

  bool get _isLargeScreen {
    final width = MediaQuery.sizeOf(context).shortestSide;
    final profile = ProviderScope.containerOf(context).read(deviceProfileProvider);
    return (profile?.isTv ?? false) || width >= 600;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlightMode = FocusManager.instance.highlightMode;
    _isKeyboardMode = _isKeyboardMode || highlightMode == FocusHighlightMode.traditional;
    final aggressiveFocus = _isLargeScreen && _isKeyboardMode;
    final focusBorderColor =
        Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.98);
    final effectiveScale = aggressiveFocus ? 1.08 : 1.02;

    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) {
        _isKeyboardMode = true;
        final custom = widget.onKeyEvent;
        if (custom != null) return custom(node, event);
        return KeyEventResult.ignored;
      },
      onFocusChange: (v) {
        setState(() => _focused = v);
        if (v) {
          _controller.forward();
        } else {
          _controller.reverse();
        }
        widget.onFocusChanged?.call(v);
      },
      child: Listener(
        onPointerDown: (_) {
          if (_isKeyboardMode) {
            setState(() => _isKeyboardMode = false);
          }
        },
        child: AnimatedBuilder(
          animation: _scale,
          builder: (context, _) => Transform.scale(
            scale: widget.disableScale || !_focused
                ? 1
                : (aggressiveFocus ? effectiveScale : _scale.value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                border: Border.all(
                  color: _focused ? focusBorderColor : Colors.transparent,
                  width: aggressiveFocus ? 3.8 : 2.5,
                ),
                boxShadow: _focused
                    ? [
                        BoxShadow(
                          color: focusBorderColor.withValues(
                            alpha: aggressiveFocus ? 0.55 : 0.4,
                          ),
                          blurRadius: aggressiveFocus ? 24 : 18,
                          spreadRadius: aggressiveFocus ? 2 : 1,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.32),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
