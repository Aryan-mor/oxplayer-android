import 'package:flutter/foundation.dart';

import 'app_debug_log.dart';

/// Captures framework and zone errors into the in-app log (debug) and [debugPrint].
void installOxplayerDebugHooks() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    final msg = details.exceptionAsString();
    final stack = details.stack?.toString() ?? '';
    debugPrint('[Oxplayer] FlutterError: $msg');
    if (stack.isNotEmpty) {
      debugPrint('[Oxplayer] FlutterError stack: $stack');
    }
    if (kDebugMode) {
      AppDebugLog.instance.log(
        'FlutterError: $msg',
        category: AppDebugLogCategory.general,
      );
      final head = stack.split('\n').take(12).join('\n');
      if (head.isNotEmpty) {
        AppDebugLog.instance.log(
          'FlutterError stack (head):\n$head',
          category: AppDebugLogCategory.general,
        );
      }
    }
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('[Oxplayer] PlatformDispatcher.onError: $error\n$stack');
    if (kDebugMode) {
      AppDebugLog.instance.log(
        'PlatformDispatcher.onError: $error',
        category: AppDebugLogCategory.general,
      );
      AppDebugLog.instance.log(
        'PlatformDispatcher stack (head):\n${stack.toString().split('\n').take(12).join('\n')}',
        category: AppDebugLogCategory.general,
      );
    }
    return true;
  };
}

