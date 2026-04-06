import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/debug/app_debug_log.dart';
import 'core/debug/debug_log_fab.dart';
import 'core/debug/layout_probe.dart';
import 'core/theme/app_theme.dart';
import 'core/oxplayer/oxplayer_screen_wrapper.dart';
import 'core/update/app_update_layer.dart';
import 'core/update/app_update_notifier.dart';
import 'providers.dart';
import 'player/external_playback_handoff.dart';
import 'player/user_preference_handoff.dart';
import 'router.dart';

class OxplayerApp extends ConsumerStatefulWidget {
  const OxplayerApp({super.key});

  @override
  ConsumerState<OxplayerApp> createState() => _OxplayerAppState();
}

class _OxplayerAppState extends ConsumerState<OxplayerApp> {
  /// Dedupe [MaterialApp.router] builder diagnostics.
  String? _lastMaterialBuilderSig;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isAndroid) {
      ExternalPlaybackHandoff.register();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        UserPreferenceHandoff.register(ref.read(authNotifierProvider));
      });
    }
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
      'OxplayerApp: Auto-initializing TDLib '
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

    final debugProductionEnabled = ref.watch(
      appConfigProvider.select((c) => c.debugProductionEnabled),
    );
    final authDebugGate = ref.watch(
      authNotifierProvider.select(
        (a) => (
          isAdmin: a.isAdmin,
        ),
      ),
    );
    final canShowDebugInRelease =
        kReleaseMode && debugProductionEnabled && authDebugGate.isAdmin;
    final canShowDebugPanel = kDebugMode || canShowDebugInRelease;
    AppDebugLog.instance.setReleaseLoggingEnabled(canShowDebugInRelease);

    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'OXPlayer',
      theme: buildOxplayerTheme(),
      routerConfig: router,
      builder: (context, child) {
        final mq = MediaQuery.sizeOf(context);
        final sig =
            '${child == null}|${child.runtimeType}|${mq.width}x${mq.height}';
        if (kDebugMode && sig != _lastMaterialBuilderSig) {
          _lastMaterialBuilderSig = sig;
          AppDebugLog.instance.log(
            'MaterialApp.builder: childNull=${child == null} '
            'childType=${child.runtimeType} mqSize=${mq.width}x${mq.height}',
            category: AppDebugLogCategory.app,
          );
        }

        // While GoRouter is resolving the first route, [child] can be null. Using
        // [SizedBox.shrink] under [Positioned.fill] / stack produced a zero-size
        // subtree on some builds (blank screen, no sidebar/list).
        final routerChild = child ??
            const ColoredBox(
              color: AppColors.bg,
              child: Center(child: CircularProgressIndicator()),
            );
        final wrapped = OxplayerScreenWrapper(
          child: SizedBox.expand(child: routerChild),
        );
        final stack = canShowDebugPanel
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
        return LayoutProbe(
          label: 'app_AppUpdateLayer',
          child: AppUpdateLayer(child: stack),
        );
      },
    );
  }
}
