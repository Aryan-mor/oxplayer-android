import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'bootstrap.dart';
import 'core/device/device_profile.dart';
import 'core/debug/oxplayer_debug_hooks.dart';
import 'providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    installOxplayerDebugHooks();
  }
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  final profile = await DeviceProfileService.resolve(
    logicalWidth: size.width,
    logicalHeight: size.height,
  );
  if (profile.isTv) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } else {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
  await bootstrap();
  runApp(
    ProviderScope(
      overrides: [
        deviceProfileProvider.overrideWith((ref) => profile),
      ],
      child: const OxplayerApp(),
    ),
  );
}
