import 'package:flutter/foundation.dart';

/// In-memory ring buffer for debug builds (TeleCima diagnostics).
class AppDebugLog extends ChangeNotifier {
  AppDebugLog._();
  static final AppDebugLog instance = AppDebugLog._();

  static const int maxLines = 3000;
  final List<String> _lines = <String>[];

  /// Append a line (no-op in release builds).
  void log(String message) {
    if (!kDebugMode) return;
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message';
    _lines.add(line);
    debugPrint(line);
    while (_lines.length > maxLines) {
      _lines.removeAt(0);
    }
    notifyListeners();
  }

  String get fullText => _lines.join('\n');

  int get lineCount => _lines.length;

  void clear() {
    if (!kDebugMode) return;
    _lines.clear();
    notifyListeners();
  }
}
