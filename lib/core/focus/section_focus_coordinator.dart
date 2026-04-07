import 'dart:async';

import 'package:flutter/material.dart';

class SectionFocusCoordinator {
  Timer? _debounce;
  String? _lastId;

  void dispose() {
    _debounce?.cancel();
  }

  void ensureSectionVisible({
    required BuildContext context,
    required String sectionId,
    Duration debounce = const Duration(milliseconds: 40),
    Duration duration = const Duration(milliseconds: 320),
    Curve curve = Curves.easeOutCubic,
    double alignment = 0.1,
  }) {
    if (_lastId == sectionId) return;
    _lastId = sectionId;
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      if (!context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: alignment,
        curve: curve,
        duration: duration,
      );
      _lastId = null;
    });
  }
}
