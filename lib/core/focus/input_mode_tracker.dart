import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dpad_navigator.dart';

enum InputMode { keyboard, pointer }

class InputModeTracker extends StatefulWidget {
  const InputModeTracker({super.key, required this.child});
  final Widget child;
  static InputMode? _debugOverrideMode;
  static InputMode? get debugOverrideMode => _debugOverrideMode;

  /// Global toggle for forcing an input mode (useful on emulator/desktop to force TV keyboard styling)
  static void toggleDebugMode(bool forceKeyboard) {
    _debugOverrideMode = forceKeyboard ? InputMode.keyboard : null;
    WidgetsBinding.instance.reassembleApplication();
  }

  static InputMode of(BuildContext context) {
    if (_debugOverrideMode != null) return _debugOverrideMode!;
    final provider = context.dependOnInheritedWidgetOfExactType<_InputModeProvider>();
    return provider?.mode ?? InputMode.pointer;
  }

  static bool isKeyboardMode(BuildContext context) =>
      _debugOverrideMode == InputMode.keyboard || of(context) == InputMode.keyboard;

  @override
  State<InputModeTracker> createState() => _InputModeTrackerState();
}

class _InputModeTrackerState extends State<InputModeTracker> {
  InputMode _mode = InputMode.pointer;


  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    // Track back key press state for automatic suppression of stray KeyUp events
    BackKeyPressTracker.handleKeyEvent(event);

    if (event is KeyDownEvent && event.logicalKey.isNavigationKey) {
      _setMode(InputMode.keyboard);
    }
    return false;
  }

  void _setMode(InputMode mode) {
    if (_mode != mode) {
      setState(() => _mode = mode);
    }
    // Keep Material focus highlights in sync with our input mode
    final desiredStrategy = mode == InputMode.keyboard
        ? FocusHighlightStrategy.alwaysTraditional
        : FocusHighlightStrategy.automatic;
    if (FocusManager.instance.highlightStrategy != desiredStrategy) {
      FocusManager.instance.highlightStrategy = desiredStrategy;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _setMode(InputMode.pointer),
      onPointerHover: (_) => _setMode(InputMode.pointer),
      behavior: HitTestBehavior.translucent,
      child: _InputModeProvider(mode: _mode, child: widget.child),
    );
  }
}

class _InputModeProvider extends InheritedWidget {
  const _InputModeProvider({required this.mode, required super.child});
  final InputMode mode;

  @override
  bool updateShouldNotify(_InputModeProvider oldWidget) => mode != oldWidget.mode;
}
