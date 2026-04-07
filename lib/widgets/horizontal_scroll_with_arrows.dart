import 'package:flutter/material.dart';

/// A wrapper that adds hover-activated navigation arrows to horizontal scrolling content.
/// Arrows only appear on non-TV (pointer) platforms and hide at scroll boundaries.
class HorizontalScrollWithArrows extends StatefulWidget {
  final Widget Function(ScrollController) builder;
  final double scrollAmount;
  final ScrollController? controller;

  const HorizontalScrollWithArrows({
    super.key,
    required this.builder,
    this.scrollAmount = 0.8,
    this.controller,
  });

  @override
  State<HorizontalScrollWithArrows> createState() => _HorizontalScrollWithArrowsState();
}

class _HorizontalScrollWithArrowsState extends State<HorizontalScrollWithArrows> {
  late final ScrollController _scrollController;
  late final bool _ownsController;
  bool _isHovering = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _scrollController = widget.controller ?? ScrollController();
    _scrollController.addListener(_updateScrollState);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollState());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateScrollState);
    if (_ownsController) _scrollController.dispose();
    super.dispose();
  }

  void _updateScrollState() {
    if (!mounted || _scrollController.positions.length != 1) {
      if (mounted && (_canScrollLeft || _canScrollRight)) {
        setState(() {
          _canScrollLeft = false;
          _canScrollRight = false;
        });
      }
      return;
    }
    final position = _scrollController.position;
    final newLeft = position.pixels > 0;
    final newRight = position.pixels < position.maxScrollExtent;
    if (newLeft != _canScrollLeft || newRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = newLeft;
        _canScrollRight = newRight;
      });
    }
  }

  void _animateScroll(double direction) {
    if (_scrollController.positions.length != 1) return;
    final position = _scrollController.position;
    final delta = direction * position.viewportDimension * widget.scrollAmount;
    final targetScroll = (position.pixels + delta).clamp(0.0, position.maxScrollExtent);
    _scrollController.animateTo(targetScroll, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  Widget _buildArrowButton({
    required double position,
    required IconData icon,
    required VoidCallback onPressed,
    required bool canScroll,
  }) {
    return Positioned(
      left: position >= 0 ? position : null,
      right: position < 0 ? -position : null,
      top: 0,
      bottom: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: (_isHovering && canScroll) ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !(_isHovering && canScroll),
            child: GestureDetector(
              onTap: onPressed,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.7),
                ),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(_scrollController);

    // On TV/Android, just return the child without arrows
    final isDesktop = Theme.of(context).platform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.windows ||
        Theme.of(context).platform == TargetPlatform.linux;

    if (!isDesktop) return child;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Stack(
        children: [
          child,
          _buildArrowButton(
            position: 8,
            icon: Icons.chevron_left_rounded,
            onPressed: () => _animateScroll(-1),
            canScroll: _canScrollLeft,
          ),
          _buildArrowButton(
            position: -8,
            icon: Icons.chevron_right_rounded,
            onPressed: () => _animateScroll(1),
            canScroll: _canScrollRight,
          ),
        ],
      ),
    );
  }
}
