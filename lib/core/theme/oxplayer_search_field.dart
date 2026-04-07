import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../focus/focus_keys.dart';
import 'app_theme.dart';
import 'focus_wrapper.dart';

/// Search row for remote / D-pad: the outer shell receives focus first (like [OxplayerButton]).
/// Select / Enter opens text entry on the inner [TextField]; Back exits typing
/// so focus can move to other targets without getting stuck in the field.
class OxplayerSearchField extends StatefulWidget {
  const OxplayerSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.autofocus = false,
    this.hintText,
    this.onSubmitted,
    this.borderRadius = 10.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    this.textStyle = const TextStyle(color: Colors.white, fontSize: 16),
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final TextStyle textStyle;

  @override
  State<OxplayerSearchField> createState() => _OxplayerSearchFieldState();
}

class _OxplayerSearchFieldState extends State<OxplayerSearchField> {
  FocusNode? _shellInternal;
  late final FocusNode _fieldFocus;
  bool _typing = false;
  bool _shellFocused = false;

  FocusNode get _shell => widget.focusNode ?? _shellInternal!;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode == null) {
      _shellInternal = FocusNode(debugLabel: 'OxplayerSearchField.shell');
    }
    _fieldFocus = FocusNode(debugLabel: 'OxplayerSearchField.field');
    widget.controller.addListener(_onControllerChanged);
    _fieldFocus.addListener(_onFieldFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _fieldFocus.removeListener(_onFieldFocusChanged);
    _shellInternal?.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onFieldFocusChanged() {
    if (!_fieldFocus.hasFocus && mounted && _typing) {
      _exitTyping(requestShellFocus: false);
    }
  }

  void _enterTyping() {
    if (_typing) return;
    setState(() => _typing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  void _exitTyping({required bool requestShellFocus}) {
    if (!_typing) return;
    setState(() => _typing = false);
    if (requestShellFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _shell.requestFocus();
      });
    }
  }

  KeyEventResult _onShellKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && FocusKeys.isActivate(event.logicalKey)) {
      _enterTyping();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildShell() {
    final empty = widget.controller.text.isEmpty;
    final hint = widget.hintText ?? '';
    return FocusWrapper(
      autofocus: widget.autofocus,
      focusNode: _shell,
      onKeyEvent: _onShellKey,
      onFocusChanged: (focused) {
        if (!mounted) return;
        setState(() => _shellFocused = focused);
      },
      child: Transform.scale(
        scale: _shellFocused ? 1.05 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: _shellFocused
                  ? AppColors.highlight
                  : Colors.transparent,
              width: 3.0,
            ),
            boxShadow: _shellFocused
                ? [
                    BoxShadow(
                      color: AppColors.highlight.withValues(alpha: 0.45),
                      blurRadius: 15,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
            color: _shellFocused
                ? AppColors.highlight.withValues(alpha: 0.15)
                : AppColors.card,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              onTap: _enterTyping,
              child: Padding(
                padding: widget.padding,
                child: Row(
                  children: [
                    const Icon(
                      Icons.search_rounded,
                      color: AppColors.textMuted,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        empty ? hint : widget.controller.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: empty
                            ? widget.textStyle.copyWith(
                                color: AppColors.textMuted
                                    .withValues(alpha: 0.85),
                              )
                            : widget.textStyle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField() {
    // Do not wrap [TextField] in [Focus] with the same [focusNode] — that
    // triggers assert 'child != this' in the focus manager.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.goBack): () {
          if (_typing) _exitTyping(requestShellFocus: true);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_typing) _exitTyping(requestShellFocus: true);
        },
      },
      child: Transform.scale(
        scale: 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: AppColors.highlight,
              width: 3.0,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.highlight.withValues(alpha: 0.45),
                blurRadius: 15,
                spreadRadius: 1,
              ),
            ],
            color: AppColors.highlight.withValues(alpha: 0.15),
          ),
          child: Material(
            color: Colors.transparent,
            child: Padding(
              padding: widget.padding,
              child: TextField(
                controller: widget.controller,
                focusNode: _fieldFocus,
                style: widget.textStyle,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    color: AppColors.textMuted.withValues(alpha: 0.85),
                  ),
                  filled: true,
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                onSubmitted: (value) {
                  widget.onSubmitted?.call(value);
                  _exitTyping(requestShellFocus: true);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _typing ? _buildField() : _buildShell();
  }
}
