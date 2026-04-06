import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'telegram/tdlib_controller.dart' if (dart.library.html) 'telegram/tdlib_controller_web.dart';

Future<void> bootstrap() async {
  try {
    await dotenv.load(fileName: 'assets/env/default.env');
  } catch (_) {
    // Non-fatal: keys can also be supplied via `--dart-define` in CI.
  }
  if (!kIsWeb) {
    await TelegramTdlibFacade.initTdlibPlugin();
  }
}
