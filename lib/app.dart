import 'dart:async';

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart';

import 'core/debug/app_debug_log.dart';
import 'core/debug/debug_log_fab.dart';
import 'core/theme/app_theme.dart';
import 'core/tv/tv_screen_wrapper.dart';
import 'data/local/isar_provider.dart';
import 'providers.dart';
import 'router.dart';

class TeleCimaApp extends ConsumerWidget {
  const TeleCimaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AsyncValue<Isar>>(isarProvider, (prev, next) {
      next.whenData((isar) {
        unawaited(ref.read(authNotifierProvider).mergeIsarSession(isar));
      });
    });

    ref.listen(authNotifierProvider, (prev, auth) {
      if (auth.isLoggedIn) {
        final facade = ref.read(tdlibFacadeProvider);
        if (!facade.isInitialized) {
          final config = ref.read(appConfigProvider);
          final apiIdStr = config.telegramApiId;
          final apiId = int.tryParse(apiIdStr) ?? 0;
          if (apiId > 0) {
            AppDebugLog.instance
                .log('TeleCimaApp: Auto-initializing TDLib for active session');
            unawaited(facade.init(
              apiId: apiId,
              apiHash: config.telegramApiHash,
              sessionString: '',
            ));
          }
        }
      }
    });

    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'TeleCima',
      theme: buildTeleCimaTheme(),
      routerConfig: router,
      builder: (context, child) {
        final wrappedChild = TVScreenWrapper(
          child: child ?? const SizedBox.shrink(),
        );
        if (!kDebugMode) {
          return wrappedChild;
        }
        // Fill the stack so the router/child gets tight constraints (avoids layout errors).
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: wrappedChild,
            ),
            const Positioned(
              right: 12,
              bottom: 12,
              child: DebugLogFab(),
            ),
          ],
        );
      },
    );
  }
}
