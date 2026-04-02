import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/debug/app_debug_log.dart';
import 'core/debug/debug_log_fab.dart';
import 'core/theme/app_theme.dart';
import 'core/tv/tv_screen_wrapper.dart';
import 'core/update/app_update_layer.dart';
import 'core/update/app_update_notifier.dart';
import 'providers.dart';
import 'router.dart';

class TeleCimaApp extends ConsumerStatefulWidget {
  const TeleCimaApp({super.key});

  @override
  ConsumerState<TeleCimaApp> createState() => _TeleCimaAppState();
}

class _TeleCimaAppState extends ConsumerState<TeleCimaApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryInitTdlib());
  }

  void _tryInitTdlib() {
    if (!ref.read(appUpdateGateReleasedProvider)) return;
    final auth = ref.read(authNotifierProvider);
    if (!auth.hasTelegramSession) return;
    final facade = ref.read(tdlibFacadeProvider);
    if (facade.isInitialized) return;
    final config = ref.read(appConfigProvider);
    final apiIdStr = config.telegramApiId;
    final apiId = int.tryParse(apiIdStr) ?? 0;
    if (apiId <= 0) return;
    AppDebugLog.instance.log(
      'TeleCimaApp: Auto-initializing TDLib '
      'facade=${identityHashCode(facade)} isInitialized=${facade.isInitialized}',
      category: AppDebugLogCategory.app,
    );
    unawaited(
      facade.init(
        apiId: apiId,
        apiHash: config.telegramApiHash,
        sessionString: '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authNotifierProvider, (_, __) => _tryInitTdlib());
    ref.listen(appUpdateGateReleasedProvider, (_, released) {
      if (released) _tryInitTdlib();
    });

    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'TeleCima',
      theme: buildTeleCimaTheme(),
      routerConfig: router,
      builder: (context, child) {
        final routerChild = child ?? const SizedBox.shrink();
        final wrapped = TVScreenWrapper(child: routerChild);
        final stack = kDebugMode
            ? Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(child: wrapped),
                  const Positioned(
                    right: 12,
                    bottom: 12,
                    child: DebugLogFab(),
                  ),
                ],
              )
            : wrapped;
        return AppUpdateLayer(child: stack);
      },
    );
  }
}
