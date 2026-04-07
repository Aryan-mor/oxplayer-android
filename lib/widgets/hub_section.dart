import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/focus/dpad_navigator.dart';
import '../core/focus/focus_theme.dart';
import '../core/focus/input_mode_tracker.dart';
import '../core/focus/key_event_utils.dart';
import '../core/focus/locked_hub_controller.dart';
import '../data/models/app_media.dart';
import 'focus_builders.dart';
import 'horizontal_scroll_with_arrows.dart';
import 'media_card.dart';


/// Data model for a hub section – identical API to old HubSectionData.
class HubSectionData {
  const HubSectionData({
    required this.hubKey,
    required this.title,
    required this.items,
    this.more = false,
  });

  final String hubKey;
  final String title;
  final List<AppMediaAggregate> items;

  /// Whether there are more items not shown (shows "View All" card).
  final bool more;
}

/// Shared hub section widget.
///
/// Uses a "locked" focus pattern where:
/// - A single Focus widget at the hub level intercepts ALL arrow keys
/// - Visual focus index is tracked in state (not Flutter's focus system)
/// - Children render focus visuals based on the passed index
/// - Focus never "escapes" to random elements
class HubSection extends StatefulWidget {
  final HubSectionData hub;
  final IconData icon;
  final ValueChanged<AppMediaAggregate>? onItemTap;

  /// Callback for vertical navigation (up/down). Return true if handled.
  final bool Function(bool isUp)? onVerticalNavigation;

  /// Called when the user presses UP while at the topmost item (first hub).
  final VoidCallback? onNavigateUp;

  /// Called when the user presses LEFT while at the leftmost item (index 0).
  final VoidCallback? onNavigateToSidebar;

  // Keep coordinator for backward compat (ignored, focus done via Scrollable.ensureVisible)
  final dynamic coordinator;
  final String? sectionId;

  const HubSection({
    super.key,
    required this.hub,
    this.icon = Icons.local_movies_rounded,
    this.onItemTap,
    this.onVerticalNavigation,
    this.onNavigateUp,
    this.onNavigateToSidebar,
    this.coordinator,
    this.sectionId,
  });

  @override
  State<HubSection> createState() => HubSectionState();
}

class HubSectionState extends State<HubSection> {
  static const _longPressDuration = Duration(milliseconds: 500);

  late FocusNode _hubFocusNode;
  final ScrollController _scrollController = ScrollController();

  /// Current visual focus index (not tied to Flutter's focus system).
  int _focusedIndex = 0;

  /// Item extent for scroll calculations.
  double _itemExtent = 230;
  static const double _leadingPadding = 12.0;

  Timer? _longPressTimer;
  bool _isSelectKeyDown = false;
  bool _longPressTriggered = false;

  @override
  void initState() {
    super.initState();
    _hubFocusNode = FocusNode(debugLabel: 'hub_${widget.hub.hubKey}');
    _hubFocusNode.addListener(_onFocusChange);
  }

  int get _totalItemCount => widget.hub.items.length + (widget.hub.more ? 1 : 0);

  @override
  void didUpdateWidget(HubSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hub.items.length != oldWidget.hub.items.length) {
      final maxIndex = _totalItemCount == 0 ? 0 : _totalItemCount - 1;
      if (_focusedIndex > maxIndex) _focusedIndex = maxIndex;
    }
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _hubFocusNode.removeListener(_onFocusChange);
    _hubFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_hubFocusNode.hasFocus) {
      _longPressTimer?.cancel();
      _isSelectKeyDown = false;
      _longPressTriggered = false;
    }
    if (mounted) setState(() {});
  }

  /// Request focus on this hub at a specific item index.
  void requestFocusAt(int index) {
    if (_totalItemCount == 0) return;
    final clamped = index.clamp(0, _totalItemCount - 1);
    _focusedIndex = clamped;
    HubFocusMemory.setForHub(widget.hub.hubKey, clamped);
    _scrollToIndex(clamped);
    _hubFocusNode.requestFocus();
    if (mounted) setState(() {});
    _scrollHubIntoView();
  }

  /// Request focus using the stored memory for this hub.
  void requestFocusFromMemory() {
    final index = HubFocusMemory.getForHub(widget.hub.hubKey, _totalItemCount);
    requestFocusAt(index);
  }

  void _scrollHubIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.3,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  bool get hasFocusedItem => _hubFocusNode.hasFocus;
  int get itemCount => _totalItemCount;

  void _scrollToIndex(int index, {bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final target = (index * _itemExtent)
        .clamp(0.0, _scrollController.position.maxScrollExtent)
        .toDouble();
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;

    if (key.isSelectKey) {
      if (event is KeyDownEvent) {
        if (!_isSelectKeyDown) {
          _isSelectKeyDown = true;
          _longPressTriggered = false;
          _longPressTimer?.cancel();
          _longPressTimer = Timer(_longPressDuration, () {
            if (!mounted) return;
            if (_isSelectKeyDown) {
              _longPressTriggered = true;
              SelectKeyUpSuppressor.suppressSelectUntilKeyUp();
              // Long press noop for now (no context menu in this app)
            }
          });
        }
        return KeyEventResult.handled;
      } else if (event is KeyRepeatEvent) {
        return KeyEventResult.handled;
      } else if (event is KeyUpEvent) {
        final timerWasActive = _longPressTimer?.isActive ?? false;
        _longPressTimer?.cancel();
        if (!_longPressTriggered && timerWasActive && _isSelectKeyDown) {
          _activateCurrentItem();
        }
        _isSelectKeyDown = false;
        _longPressTriggered = false;
        return KeyEventResult.handled;
      }
    }

    if (!event.isActionable) return KeyEventResult.ignored;

    final totalCount = _totalItemCount;
    if (totalCount == 0) return KeyEventResult.ignored;

    if (key.isLeftKey) {
      if (_focusedIndex > 0) {
        setState(() => _focusedIndex--);
        HubFocusMemory.setForHub(widget.hub.hubKey, _focusedIndex);
        _scrollToIndex(_focusedIndex);
      } else if (widget.onNavigateToSidebar != null) {
        widget.onNavigateToSidebar!();
      }
      return KeyEventResult.handled;
    }

    if (key.isRightKey) {
      if (_focusedIndex < totalCount - 1) {
        setState(() => _focusedIndex++);
        HubFocusMemory.setForHub(widget.hub.hubKey, _focusedIndex);
        _scrollToIndex(_focusedIndex);
      }
      return KeyEventResult.handled;
    }

    if (key.isUpKey) {
      final handled = widget.onVerticalNavigation?.call(true) ?? false;
      if (!handled && widget.onNavigateUp != null) {
        widget.onNavigateUp!();
      }
      return KeyEventResult.handled;
    }

    if (key.isDownKey) {
      widget.onVerticalNavigation?.call(false);
      return KeyEventResult.handled;
    }

    if (key.isContextMenuKey) {
      // noop context menu
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _activateCurrentItem() {
    if (_focusedIndex >= widget.hub.items.length) return;
    final item = widget.hub.items[_focusedIndex];
    widget.onItemTap?.call(item);
  }

  @override
  Widget build(BuildContext context) {
    final hasFocus = _hubFocusNode.hasFocus;
    final isKeyboardMode = InputModeTracker.isKeyboardMode(context);

    const double cardWidth = 220;
    const double posterWidth = cardWidth - 6;
    const double posterHeight = posterWidth * 1.5; // 2:3 ratio
    const double containerHeight = posterHeight + 48;
    const double focusExtra = FocusTheme.focusBorderWidth * 2;
    _itemExtent = cardWidth + focusExtra + 4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Hub header
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          child: ExcludeFocus(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.hub.title,
                      style: Theme.of(context).textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Hub items with locked focus control
        if (widget.hub.items.isNotEmpty)
          Focus(
            focusNode: _hubFocusNode,
            onKeyEvent: _handleKeyEvent,
            child: SizedBox(
              height: containerHeight + focusExtra + 4,
              child: HorizontalScrollWithArrows(
                controller: _scrollController,
                builder: (scrollController) => ListView.builder(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.symmetric(horizontal: _leadingPadding - 4, vertical: 2),
                  itemCount: isKeyboardMode ? _totalItemCount : widget.hub.items.length,
                  itemBuilder: (context, index) {
                    final isItemFocused = hasFocus && index == _focusedIndex;

                    if (index == widget.hub.items.length && widget.hub.more) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: FocusBuilders.buildLockedFocusWrapper(
                          context: context,
                          isFocused: isItemFocused,
                          onTap: () => _onItemTapped(index),
                          child: SizedBox(
                            width: 80,
                            height: containerHeight - 10,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.arrow_forward_rounded,
                                    size: 32,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'View All',
                                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }

                    final item = widget.hub.items[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: FocusBuilders.buildLockedFocusWrapper(
                        context: context,
                        isFocused: isItemFocused,
                        onTap: () => _onItemTapped(index),
                        child: MediaCard(
                          item: item,
                          onTap: () => _onItemTapped(index),
                          width: cardWidth,
                          height: posterHeight,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No items available',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ),
      ],
    );
  }

  void _onItemTapped(int index) {
    setState(() => _focusedIndex = index);
    HubFocusMemory.setForHub(widget.hub.hubKey, index);
    _hubFocusNode.requestFocus();
    if (index < widget.hub.items.length) {
      widget.onItemTap?.call(widget.hub.items[index]);
    }
  }
}

