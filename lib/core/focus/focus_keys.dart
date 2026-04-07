import 'package:flutter/services.dart';

class FocusKeys {
  const FocusKeys._();

  static bool isCenterOrSelect(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.select) return true;
    final label = key.keyLabel.toLowerCase();
    if (label == 'center' || label == 'dpad center' || label == 'select') {
      return true;
    }
    return key.keyId == 0x00100000017 || key.keyId == 23;
  }

  static bool isActivate(LogicalKeyboardKey key) {
    return isCenterOrSelect(key) ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA;
  }
}
