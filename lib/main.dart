import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'dart:io' show Platform, ProcessInfo;
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'screens/main_screen.dart';
import 'screens/auth_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'app.dart';
import 'services/storage_service.dart';
import 'services/macos_window_service.dart';
import 'services/fullscreen_state_manager.dart';
import 'services/settings_service.dart';
import 'utils/platform_detector.dart';
import 'services/discord_rpc_service.dart';
import 'services/gamepad_service.dart';
import 'providers/user_profile_provider.dart';
import 'providers/multi_server_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/hidden_libraries_provider.dart';
import 'providers/libraries_provider.dart';
import 'providers/playback_state_provider.dart';
import 'providers/download_provider.dart';
import 'providers/offline_mode_provider.dart';
import 'providers/offline_watch_provider.dart';
import 'providers/companion_remote_provider.dart';
import 'providers/shader_provider.dart';
import 'utils/snackbar_helper.dart';
import 'watch_together/watch_together.dart';
import 'services/multi_server_manager.dart';
import 'services/offline_watch_sync_service.dart';
import 'services/server_connection_orchestrator.dart';
import 'services/data_aggregation_service.dart';
import 'services/in_app_review_service.dart';
import 'services/server_registry.dart';
import 'services/download_manager_service.dart';
import 'services/pip_service.dart';
import 'services/download_storage_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'services/plex_api_cache.dart';
import 'database/app_database.dart';
import 'utils/app_logger.dart';
import 'utils/orientation_helper.dart';
import 'i18n/strings.g.dart';
import 'bootstrap.dart';
import 'core/focus/input_mode_tracker.dart';
import 'focus/key_event_utils.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'utils/navigation_transitions.dart';
import 'utils/log_redaction_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';

const bool _enableSentry = bool.fromEnvironment('ENABLE_SENTRY', defaultValue: false);
const String gitCommit = String.fromEnvironment('GIT_COMMIT');

// Workaround for Flutter bug #177992: iPadOS 26.1+ misinterprets fake touch events
// at (0,0) as barrier taps, causing modals to dismiss immediately.
// Remove when Flutter PR #179643 is merged.
bool _zeroOffsetPointerGuardInstalled = false;

void _installZeroOffsetPointerGuard() {
  if (_zeroOffsetPointerGuardInstalled) return;
  GestureBinding.instance.pointerRouter.addGlobalRoute(_absorbZeroOffsetPointerEvent);
  _zeroOffsetPointerGuardInstalled = true;
}

void _absorbZeroOffsetPointerEvent(PointerEvent event) {
  if (event.position == Offset.zero) {
    GestureBinding.instance.cancelPointer(event.pointer);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installZeroOffsetPointerGuard(); // Workaround for iPadOS 26.1+ modal dismissal bug

  if (_enableSentry) {
    final packageInfo = await PackageInfo.fromPlatform();

    await SentryFlutter.init((options) {
      options.dsn = 'https://6a1a6ef8c72140099b2798973c1bfb2f@bugs.plezy.app/1';
      options.release = gitCommit.isNotEmpty
          ? 'plezy@${gitCommit.substring(0, 7)}'
          : 'plezy@${packageInfo.version}+${packageInfo.buildNumber}';
      options.tracesSampleRate = 0;
      options.attachStacktrace = true;
      options.enableAutoSessionTracking = false;
      options.recordHttpBreadcrumbs = false;
      options.beforeSend = _beforeSend;
      options.beforeBreadcrumb = _beforeBreadcrumb;
    }, appRunner: _bootstrapApp);
    return;
  }

  await _bootstrapApp();
}

Future<void> _bootstrapApp() async {
  await bootstrap();

  // Initialize settings first to get saved locale
  final settings = await SettingsService.getInstance();
  final savedLocale = settings.getAppLocale();

  // Initialize localization with saved locale
  LocaleSettings.setLocale(savedLocale);

  // Needed for formatting dates in different locales
  await initializeDateFormatting(savedLocale.languageCode, null);

  // Configure image cache — keep budget modest to leave headroom for Skia decode buffers
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    PaintingBinding.instance.imageCache.maximumSize = 1000;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 150 << 20; // 150MB
  } else {
    PaintingBinding.instance.imageCache.maximumSize = 800;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20; // 100MB
  }

  // Initialize services in parallel where possible
  final futures = <Future<void>>[];

  // Initialize window_manager for desktop platforms
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    futures.add(windowManager.ensureInitialized());
  }

  // Initialize TV detection and PiP service for Android
  if (Platform.isAndroid) {
    futures.add(TvDetectionService.getInstance());
    // Initialize PiP service to listen for PiP state changes
    PipService();
  }

  // Configure macOS window with custom titlebar (depends on window manager)
  futures.add(MacOSWindowService.setupCustomTitlebar());

  // Initialize storage service
  futures.add(StorageService.getInstance());

  // Wait for all parallel services to complete
  await Future.wait(futures);

  // Initialize logger level based on debug setting
  final debugEnabled = settings.getEnableDebugLogging();
  setLoggerLevel(debugEnabled);

  // Log app version and git commit at startup
  final packageInfo = await PackageInfo.fromPlatform();
  final commitSuffix = gitCommit.isNotEmpty ? ' (${gitCommit.substring(0, 7)})' : '';
  appLogger.i('OxPlayer v${packageInfo.version}+${packageInfo.buildNumber}$commitSuffix');

  // Initialize download storage service with settings
  await DownloadStorageService.instance.initialize(settings);

  // Start global fullscreen state monitoring
  FullscreenStateManager().startMonitoring();

  // Initialize gamepad service (all platforms — universal_gamepad auto-registers
  // and intercepts input events, so we must listen to re-dispatch them)
  GamepadService.instance.start();

  // Desktop-only services
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    DiscordRPCService.instance.initialize();
  }

  // DTD service is available for MCP tooling connection if needed

  // Register bundled shader licenses
  _registerShaderLicenses();

  runApp(const riverpod.ProviderScope(child: _LegacyProviderScope(child: OxplayerApp())));
}

class _LegacyProviderScope extends StatelessWidget {
  final Widget child;

  const _LegacyProviderScope({required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>(
          create: (_) => AppDatabase(),
          dispose: (_, db) => db.close(),
        ),
        Provider<MultiServerManager>(
          create: (_) => MultiServerManager(),
          dispose: (_, manager) => manager.dispose(),
        ),
        Provider<DataAggregationService>(
          create: (context) => DataAggregationService(context.read<MultiServerManager>()),
        ),
        Provider<DownloadManagerService>(
          create: (context) => DownloadManagerService(
            database: context.read<AppDatabase>(),
            storageService: DownloadStorageService.instance,
          ),
          dispose: (_, service) => service.dispose(),
        ),
        ChangeNotifierProvider<OfflineWatchSyncService>(
          create: (context) => OfflineWatchSyncService(
            database: context.read<AppDatabase>(),
            serverManager: context.read<MultiServerManager>(),
          ),
        ),
        ChangeNotifierProvider<MultiServerProvider>(
          create: (context) => MultiServerProvider(
            context.read<MultiServerManager>(),
            context.read<DataAggregationService>(),
          ),
        ),
        ChangeNotifierProvider<OfflineModeProvider>(
          create: (context) {
            final provider = OfflineModeProvider(context.read<MultiServerManager>());
            unawaited(provider.initialize());
            return provider;
          },
        ),
        ChangeNotifierProvider<UserProfileProvider>(create: (_) => UserProfileProvider()),
        ChangeNotifierProvider<ThemeProvider>(create: (_) => ThemeProvider()),
        ChangeNotifierProvider<SettingsProvider>(create: (_) => SettingsProvider()),
        ChangeNotifierProvider<HiddenLibrariesProvider>(create: (_) => HiddenLibrariesProvider()),
        ChangeNotifierProvider<LibrariesProvider>(create: (_) => LibrariesProvider()),
        ChangeNotifierProvider<PlaybackStateProvider>(create: (_) => PlaybackStateProvider()),
        ChangeNotifierProvider<CompanionRemoteProvider>(create: (_) => CompanionRemoteProvider()),
        ChangeNotifierProvider<ShaderProvider>(create: (_) => ShaderProvider()),
        ChangeNotifierProvider<WatchTogetherProvider>(create: (_) => WatchTogetherProvider()),
        ChangeNotifierProvider<DownloadProvider>(
          create: (context) {
            final provider = DownloadProvider(downloadManager: context.read<DownloadManagerService>());
            final syncService = context.read<OfflineWatchSyncService>();
            syncService.onWatchStatesRefreshed = () {
              unawaited(provider.refreshMetadataFromCache());
            };
            return provider;
          },
        ),
        ChangeNotifierProvider<OfflineWatchProvider>(
          create: (context) {
            final syncService = context.read<OfflineWatchSyncService>();
            syncService.startConnectivityMonitoring(context.read<OfflineModeProvider>());
            return OfflineWatchProvider(
              syncService: syncService,
              downloadProvider: context.read<DownloadProvider>(),
            );
          },
        ),
      ],
      child: child,
    );
  }
}

Breadcrumb? _beforeBreadcrumb(Breadcrumb? breadcrumb, Hint _) {
  if (breadcrumb == null) return null;

  final message = breadcrumb.message;
  final data = breadcrumb.data;
  if (message == null && (data == null || data.isEmpty)) return breadcrumb;

  if (message != null) breadcrumb.message = LogRedactionManager.redact(message);
  if (data != null) breadcrumb.data = data.map((k, v) => MapEntry(k, v is String ? LogRedactionManager.redact(v) : v));
  return breadcrumb;
}

FutureOr<SentryEvent?> _beforeSend(SentryEvent event, Hint _) {
  // Drop event if user opted out of crash reporting
  final instance = SettingsService.instanceOrNull;
  if (instance != null && !instance.getCrashReporting()) return null;

  // Drop harmless Windows file-lock errors from cache manager cleanup
  var exceptions = event.exceptions;
  if (exceptions != null &&
      exceptions.any(
        (e) =>
            e.type == 'FileSystemException' &&
            e.value != null &&
            e.value!.contains('plexImageCache') &&
            e.value!.contains('errno = 32'),
      )) {
    return null;
  }

  // Drop DBusServiceUnknownException from Linux without NetworkManager
  if (exceptions != null && exceptions.any((e) => e.type == 'DBusServiceUnknownException')) {
    return null;
  }

  // Scrub Plex tokens and server URLs from exception messages
  if (exceptions != null) {
    for (final e in exceptions) {
      final value = e.value;
      if (value != null) {
        e.value = LogRedactionManager.redact(value);
      }
    }
  }

  // Scrub breadcrumb messages and data
  final breadcrumbs = event.breadcrumbs;
  if (breadcrumbs != null) {
    for (final b in breadcrumbs) {
      final message = b.message;
      final data = b.data;
      if (message != null) b.message = LogRedactionManager.redact(message);
      if (data != null) b.data = data.map((k, v) => MapEntry(k, v is String ? LogRedactionManager.redact(v) : v));
    }
  }

  return event;
}

void _registerShaderLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['Anime4K'],
      'MIT License\n'
      '\n'
      'Copyright (c) 2019-2021 bloc97\n'
      'All rights reserved.\n'
      '\n'
      'Permission is hereby granted, free of charge, to any person obtaining a copy '
      'of this software and associated documentation files (the "Software"), to deal '
      'in the Software without restriction, including without limitation the rights '
      'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell '
      'copies of the Software, and to permit persons to whom the Software is '
      'furnished to do so, subject to the following conditions:\n'
      '\n'
      'The above copyright notice and this permission notice shall be included in all '
      'copies or substantial portions of the Software.\n'
      '\n'
      'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR '
      'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, '
      'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE '
      'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER '
      'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, '
      'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE '
      'SOFTWARE.',
    );
    yield const LicenseEntryWithLineBreaks(
      ['NVIDIA Image Scaling (NVScaler)'],
      'The MIT License (MIT)\n'
      '\n'
      'Copyright (c) 2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.\n'
      '\n'
      'Permission is hereby granted, free of charge, to any person obtaining a copy of '
      'this software and associated documentation files (the "Software"), to deal in '
      'the Software without restriction, including without limitation the rights to '
      'use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of '
      'the Software, and to permit persons to whom the Software is furnished to do so, '
      'subject to the following conditions:\n'
      '\n'
      'The above copyright notice and this permission notice shall be included in all '
      'copies or substantial portions of the Software.\n'
      '\n'
      'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR '
      'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS '
      'FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR '
      'COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER '
      'IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN '
      'CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.',
    );
  });
}



