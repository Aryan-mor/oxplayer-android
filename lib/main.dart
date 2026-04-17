import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'dart:io' show Platform, ProcessInfo;
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:dio/dio.dart';
import 'screens/main_screen.dart';
import 'infrastructure/data_repository.dart';
import 'infrastructure/config/app_config.dart';
import 'providers/auth_notifier.dart';
import 'services/storage_service.dart';
import 'services/cast_service.dart';
import 'services/tv_cast_receiver_service.dart';
import 'services/auth_debug_service.dart';
import 'router.dart';
import 'services/macos_window_service.dart';
import 'services/fullscreen_state_manager.dart';
import 'services/settings_service.dart';
import 'services/subtitle_search_locale_bridge.dart';
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
import 'focus/input_mode_tracker.dart';
import 'focus/key_event_utils.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'utils/navigation_transitions.dart';
import 'utils/log_redaction_manager.dart';
import 'utils/navigation_keys.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'widgets/auth_debug_fab.dart';
import 'screens/telegram/telegram_video_metadata.dart';
import 'utils/video_player_navigation.dart';

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
    SubtitleSearchLocaleBridge.register();
  }

  // Configure macOS window with custom titlebar (depends on window manager)
  futures.add(MacOSWindowService.setupCustomTitlebar());

  // Initialize storage service
  futures.add(StorageService.getInstance());

  // Wait for all parallel services to complete
  await Future.wait(futures);

  // In debug builds: apply the TV-mode simulation override persisted in settings.
  if (kDebugMode && settings.getSimulateTvMode()) {
    TvDetectionService.setTvOverride(true);
  }

  // Initialize logger level and auth debug UI based on debug setting
  final debugEnabled = settings.getEnableDebugLogging();
  applyDebugLoggingPreference(debugEnabled);

  // Log app version and git commit at startup
  final packageInfo = await PackageInfo.fromPlatform();
  final commitSuffix = gitCommit.isNotEmpty ? ' (${gitCommit.substring(0, 7)})' : '';
  String renderer = '';
  if (Platform.isAndroid) {
    renderer = ' [${await const MethodChannel('com.plezy/theme').invokeMethod<String>('getRenderer')}]';
  }
  appLogger.i('OXPlayer v${packageInfo.version}+${packageInfo.buildNumber}$commitSuffix$renderer');

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

  runApp(const MainApp());
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

// Global RouteObserver for tracking navigation
final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  // Initialize multi-server infrastructure
  late final MultiServerManager _serverManager;
  late final DataAggregationService _aggregationService;
  late final AppDatabase _appDatabase;
  late final DownloadManagerService _downloadManager;
  late final OfflineWatchSyncService _offlineWatchSyncService;
  late final AppLifecycleListener _appLifecycleListener;
  CastService? _castService;
  StorageService? _storageService;
  TvCastReceiverService? _tvCastReceiverService;

  /// Last time server health probes ran from a resume event (cooldown for desktop)
  DateTime _lastResumeProbe = DateTime(0);

  /// Periodic memory check timer for desktop platforms
  Timer? _memoryCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Initialize services asynchronously
    _initializeServices();

    // On desktop, periodically check RSS and evict image cache if too high
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      _memoryCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        final rss = ProcessInfo.currentRss;
        if (rss > 1536 * 1024 * 1024) { // 1.5GB
          appLogger.w('RSS high ($rss bytes), evicting image caches');
          _evictImageCaches();
        }
      });
    }

    _serverManager = MultiServerManager();
    _aggregationService = DataAggregationService(_serverManager);
    _appDatabase = AppDatabase();

    // Initialize API cache with database
    PlexApiCache.initialize(_appDatabase);

    _downloadManager = DownloadManagerService(database: _appDatabase, storageService: DownloadStorageService.instance);
    _downloadManager.recoveryFuture = _downloadManager.recoverInterruptedDownloads();

    _offlineWatchSyncService = OfflineWatchSyncService(database: _appDatabase, serverManager: _serverManager);

    _appLifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _appDatabase.close();
        return AppExitResponse.exit;
      },
    );

    // Start in-app review session tracking
    InAppReviewService.instance.startSession();
    
    // TV Cast Receiver is completely disabled by default to prevent "not responding" issues
    // It will only be enabled when user explicitly opens the cast modal
    if (TvDetectionService.isTVSync()) {
      appLogger.i('[Cast] TV: TV Cast Receiver disabled by default to prevent ANR issues');
      castDebugInfo('TV: TV Cast Receiver disabled by default to prevent ANR issues');
      castDebugInfo('TV: Cast receiver will be enabled when user opens cast modal');
    }
  }

  Future<void> _initializeServices() async {
    try {
      // Initialize StorageService
      _storageService = await StorageService.getInstance();
      appLogger.i('[Cast] StorageService initialized successfully');
      
      // Initialize CastService
      final config = await AppConfig.load();
      final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
      _castService = CastService(dio: dio, baseUrl: config.apiBaseUrl);
      appLogger.i('[Cast] CastService initialized successfully');
      castDebugSuccess('CastService initialized successfully');
      
      // Initialize TV Cast Receiver Service on TV devices
      if (TvDetectionService.isTVSync()) {
        appLogger.i('[Cast] TV device detected - initializing TV Cast Receiver Service');
        castDebugInfo('TV device detected - initializing TV Cast Receiver Service');
        
        // Initialize the service but don't start polling yet
        final accessToken = _storageService?.getApiAccessToken()?.trim() ?? '';
        if (accessToken.isNotEmpty) {
          _tvCastReceiverService = TvCastReceiverService(
            dio: dio,
            baseUrl: config.apiBaseUrl,
            storageService: _storageService!,
          );
          
          // Set up cast job handler
          _tvCastReceiverService!.onCastJobReceived = _handleCastJobReceived;
          
          appLogger.i('[Cast] TV Cast Receiver Service initialized (polling not started)');
          castDebugSuccess('TV Cast Receiver Service initialized (polling not started)');
        } else {
          appLogger.w('[Cast] TV: No access token available, cannot initialize cast receiver');
          castDebugWarning('TV: No access token available, cannot initialize cast receiver');
        }
      } else {
        appLogger.d('[Cast] Not a TV device - TV Cast Receiver Service not needed');
      }
      
      // Trigger rebuild to show cast button and provide services
      if (mounted) setState(() {});
    } catch (e) {
      appLogger.e('[Cast] Failed to initialize services: $e');
      castDebugError('Failed to initialize services: $e');
    }
  }

  /// Handle received cast job on TV devices
  void _handleCastJobReceived(CastJobData jobData) async {
    appLogger.i('[Cast] TV: Received cast job - ${jobData.fileName}');
    castDebugSuccess('TV: Received cast job - ${jobData.fileName}');
    
    // Log the received job details for debugging
    appLogger.i('[Cast] TV: Cast job details:');
    castDebugInfo('TV: Cast job details:');
    castDebugInfo('  - File: ${jobData.fileName}');
    castDebugInfo('  - FileId: ${jobData.fileId}');
    castDebugInfo('  - ChatId: ${jobData.chatId}');
    castDebugInfo('  - MessageId: ${jobData.messageId}');
    castDebugInfo('  - MimeType: ${jobData.mimeType}');
    castDebugInfo('  - Size: ${jobData.totalBytes} bytes');
    castDebugInfo('  - Thumbnail: ${jobData.thumbnailUrl ?? "none"}');
    castDebugInfo('  - Metadata: ${jobData.metadata}');
    
    try {
      final repo = await DataRepository.create();
      
      // Check if this is Telegram content (has numeric chatId and messageId)
      final chatIdInt = int.tryParse(jobData.chatId);
      final isTelegramContent = chatIdInt != null && jobData.messageId > 0;
      
      if (!isTelegramContent) {
        throw Exception('Non-Telegram content not yet supported for TV casting');
      }
      
      // Extract locator information from cast job metadata
      final locatorType = jobData.metadata?['locatorType'] as String?;
      final fileUniqueId = jobData.metadata?['fileUniqueId'] as String?;
      
      // Use resolveOxMediaStreamUrlForPlayback - same method as mobile device
      // This method can handle cases where the chatId might be a bot ID instead of the actual chat
      appLogger.i('[Cast] TV: Resolving stream URL using locator - chatId=$chatIdInt messageId=${jobData.messageId} locatorType=$locatorType fileUniqueId=$fileUniqueId');
      castDebugInfo('TV: Resolving stream URL using locator - chatId=$chatIdInt messageId=${jobData.messageId} locatorType=$locatorType fileUniqueId=$fileUniqueId');
      
      final streamUri = await repo.resolveOxMediaStreamUrlForPlayback(
        mediaId: jobData.fileId,
        fileUniqueId: fileUniqueId,
        locatorType: locatorType,
        locatorChatId: chatIdInt,
        locatorMessageId: jobData.messageId,
        locatorRemoteFileId: jobData.fileId,
      );
      
      if (streamUri == null) {
        throw Exception('Failed to resolve streaming URL - resolveOxMediaStreamUrlForPlayback returned null');
      }
      
      final streamUrl = streamUri.toString();
      appLogger.i('[Cast] TV: Streaming URL resolved: $streamUrl');
      castDebugSuccess('TV: Streaming URL resolved');
      
      // Create metadata and navigate to player
      final row = OxChatMediaRow(
        chatId: chatIdInt,
        messageId: jobData.messageId.toString(),
        fileId: jobData.fileId,
        fileName: jobData.fileName,
        fileSizeBytes: jobData.totalBytes,
        durationSeconds: jobData.metadata?['duration'] as int?,
        caption: jobData.metadata?['title'] as String?,
        messageDate: jobData.createdAt.toIso8601String(),
      );
      
      final metadata = TelegramVideoMetadata(row, jobData.thumbnailUrl ?? '');
      
      appLogger.i('[Cast] TV: Opening video player for ${jobData.fileName}');
      castDebugSuccess('TV: Opening video player for ${jobData.fileName}');
      
      final context = rootNavigatorKey.currentContext;
      if (context == null) {
        throw Exception('Root navigator context not available');
      }
      
      // Check if context is still mounted before using it
      if (!context.mounted) {
        throw Exception('Context is no longer mounted');
      }
      
      await navigateToInternalVideoPlayerForUrl(
        context,
        metadata: metadata,
        videoUrl: streamUrl,
      );
      
      appLogger.i('[Cast] TV: Video player opened successfully');
      castDebugSuccess('TV: Video player opened successfully');
      
    } catch (e, stackTrace) {
      appLogger.e('[Cast] TV: Failed to start playback for cast job', error: e, stackTrace: stackTrace);
      castDebugError('TV: Failed to start playback: $e');
      
      // Show error notification to user
      final context = rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        showErrorSnackBar(context, 'Cast playback failed: ${e.toString()}');
      }
    }
  }

  /// Initialize TV Cast Receiver when user explicitly requests it (on-demand)
  void initializeTvCastReceiverWhenReady() {
    if (!TvDetectionService.isTVSync()) return;
    if (_tvCastReceiverService != null) return; // Already initialized
    
    appLogger.i('[Cast] TV: Initializing TV Cast Receiver on user request');
    castDebugInfo('TV: Initializing TV Cast Receiver on user request');
    
    // Check authentication and initialize immediately
    final token = _storageService?.getApiAccessToken()?.trim() ?? '';
    if (token.isNotEmpty) {
      unawaited(_initializeTvCastReceiver());
    } else {
      castDebugError('TV: No authentication token available, cannot enable cast receiver');
    }
  }

  /// Internal method to initialize and start the TV Cast Receiver
  Future<void> _initializeTvCastReceiver() async {
    try {
      if (_tvCastReceiverService == null) {
        final config = await AppConfig.load();
        final dio = Dio(BaseOptions(baseUrl: config.apiBaseUrl));
        
        _tvCastReceiverService = TvCastReceiverService(
          dio: dio,
          baseUrl: config.apiBaseUrl,
          storageService: _storageService!,
        );
        
        // Set up cast job handler
        _tvCastReceiverService!.onCastJobReceived = _handleCastJobReceived;
        
        appLogger.i('[Cast] TV Cast Receiver Service initialized');
        castDebugSuccess('TV Cast Receiver Service initialized');
      }
      
      // Start polling (returns void, not Future)
      _tvCastReceiverService!.startPolling();
      appLogger.i('[Cast] TV Cast Receiver polling started');
      castDebugSuccess('TV Cast Receiver polling started');
      
      if (mounted) setState(() {});
    } catch (e) {
      appLogger.e('[Cast] Failed to initialize TV Cast Receiver: $e');
      castDebugError('Failed to initialize TV Cast Receiver: $e');
    }
  }

  @override
  void dispose() {
    _memoryCheckTimer?.cancel();
    _tvCastReceiverService?.dispose();
    _appLifecycleListener.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    appLogger.w('System memory pressure, evicting image caches');
    _evictImageCaches();
  }

  void _evictImageCaches() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // App came back to foreground - trigger sync check and start new session
        _offlineWatchSyncService.onAppResumed();
        InAppReviewService.instance.startSession();
        
        // Re-probe servers — mobile OS may have dropped TCP connections during doze/sleep.
        // On desktop, resumed fires on every window focus (alt-tab), so apply a cooldown
        // to avoid piling up network probes from rapid alt-tabbing.
        final now = DateTime.now();
        final cooldown = (Platform.isIOS || Platform.isAndroid)
            ? const Duration(seconds: 10)
            : const Duration(minutes: 2);
        if (now.difference(_lastResumeProbe) >= cooldown) {
          _lastResumeProbe = now;
          _serverManager.checkServerHealth();
          _serverManager.reconnectOfflineServers();
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Database is session-scoped and must survive suspend/resume.
        // Closing here would kill the Drift isolate channel while services
        // (sync, downloads, cache) still hold references to the executor.
        // SQLite WAL mode handles process death; desktop uses onExitRequested.
        InAppReviewService.instance.endSession();
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          if (ProcessInfo.currentRss > 1024 * 1024 * 1024) { // 1GB
            _evictImageCaches();
          }
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Transitional states - don't trigger session events
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => MultiServerProvider(_serverManager, _aggregationService)),
        // Offline mode provider - depends on MultiServerProvider
        ChangeNotifierProxyProvider<MultiServerProvider, OfflineModeProvider>(
          create: (_) {
            final provider = OfflineModeProvider(_serverManager);
            provider.initialize(); // Initialize immediately so statusStream listener is ready
            return provider;
          },
          update: (_, multiServerProvider, previous) {
            final provider = previous ?? OfflineModeProvider(_serverManager);
            provider.initialize(); // Idempotent - safe to call again
            return provider;
          },
        ),
        // Download provider
        ChangeNotifierProvider(create: (context) => DownloadProvider(downloadManager: _downloadManager)),
        // Offline watch sync service
        ChangeNotifierProvider<OfflineWatchSyncService>(
          create: (context) {
            final offlineModeProvider = context.read<OfflineModeProvider>();
            final downloadProvider = context.read<DownloadProvider>();

            // Wire up callback to refresh download provider after watch state sync
            _offlineWatchSyncService.onWatchStatesRefreshed = () {
              downloadProvider.refreshMetadataFromCache();
            };

            _offlineWatchSyncService.startConnectivityMonitoring(offlineModeProvider);
            return _offlineWatchSyncService;
          },
        ),
        // Offline watch provider - depends on sync service and download provider
        ChangeNotifierProxyProvider2<OfflineWatchSyncService, DownloadProvider, OfflineWatchProvider>(
          create: (context) => OfflineWatchProvider(
            syncService: _offlineWatchSyncService,
            downloadProvider: context.read<DownloadProvider>(),
          ),
          update: (_, syncService, downloadProvider, previous) {
            return previous ?? OfflineWatchProvider(syncService: syncService, downloadProvider: downloadProvider);
          },
        ),
        // Existing providers
        ChangeNotifierProvider(create: (context) => UserProfileProvider()),
        ChangeNotifierProvider(create: (context) => AuthNotifier()),
        ChangeNotifierProvider(create: (context) => ThemeProvider()),
        ChangeNotifierProvider(create: (context) => SettingsProvider(), lazy: true),
        ChangeNotifierProvider(create: (context) => HiddenLibrariesProvider(), lazy: true),
        ChangeNotifierProvider(create: (context) => LibrariesProvider()),
        ChangeNotifierProvider(create: (context) => PlaybackStateProvider()),
        ChangeNotifierProvider(create: (context) => WatchTogetherProvider()),
        ChangeNotifierProvider(create: (context) => CompanionRemoteProvider()),
        ChangeNotifierProvider(create: (context) => ShaderProvider()),
        // Storage service provider
        Provider<StorageService?>(
          create: (_) => _storageService,
        ),
        // Cast service provider
        Provider<CastService?>(
          create: (_) => _castService,
        ),
        // TV Cast Receiver Service provider - NOT initialized automatically
        Provider<TvCastReceiverService?>(
          create: (_) => _tvCastReceiverService,
        ),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, child) {
          return TranslationProvider(
            child: InputModeTracker(
              child: MaterialApp(
                title: t.app.title,
                debugShowCheckedModeBanner: false,
                navigatorKey: rootNavigatorKey,
                theme: themeProvider.lightTheme,
                darkTheme: themeProvider.darkTheme,
                themeMode: themeProvider.materialThemeMode,
                navigatorObservers: [routeObserver, BackKeySuppressorObserver()],
                home: const AppRouter(),
                builder: (context, child) => ScaffoldMessenger(
                  key: rootScaffoldMessengerKey,
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    body: Stack(
                      children: [
                        child ?? const SizedBox.shrink(),
                        const AuthDebugFab(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class OrientationAwareSetup extends StatefulWidget {
  const OrientationAwareSetup({super.key});

  @override
  State<OrientationAwareSetup> createState() => _OrientationAwareSetupState();
}

class _OrientationAwareSetupState extends State<OrientationAwareSetup> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setOrientationPreferences();
  }

  void _setOrientationPreferences() {
    OrientationHelper.restoreDefaultOrientations(context);
  }

  @override
  Widget build(BuildContext context) {
    return const SetupScreen();
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  String _statusMessage = 'Securing session with OXPlayer API...';

  // Per-server connection status: serverId -> (name, connected?)
  final Map<String, (String name, bool? connected)> _serverStatus = {};

  Future<bool> _isApiReachable({required bool hasNetwork}) async {
    if (!hasNetwork) return false;
    return DataRepository.probeApiHealth();
  }

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  void _setStatus(String message) {
    if (mounted) setState(() => _statusMessage = message);
  }

  Future<void> _loadSavedCredentials() async {
    _setStatus(t.common.checkingNetwork);

    final authNotifier = context.read<AuthNotifier>();

    final storage = await StorageService.getInstance();
    final registry = ServerRegistry(storage);
    final hasPersistedSession = authNotifier.hasPersistedSession;

    // Check network connectivity early to fast-path airplane mode.
    // Timeout guards against connectivity_plus hanging on some Android TV devices after force-close.
    bool hasNetwork;
    Sentry.addBreadcrumb(Breadcrumb(message: 'Checking network connectivity', category: 'setup'));
    try {
      final connectivityResult = await Connectivity().checkConnectivity().timeout(
        const Duration(seconds: 3),
        onTimeout: () => [ConnectivityResult.other],
      );
      hasNetwork = !connectivityResult.contains(ConnectivityResult.none);
    } catch (e) {
      // connectivity_plus throws DBusServiceUnknownException on Linux without NetworkManager
      hasNetwork = true;
    }

    Sentry.addBreadcrumb(Breadcrumb(message: 'Network check done: hasNetwork=$hasNetwork', category: 'setup'));

    var oxBootstrapReady = false;
    var pendingOxApiRecovery = false;
    if (hasNetwork && authNotifier.apiAccessToken != null && authNotifier.apiAccessToken!.isNotEmpty) {
      DataRepository? repository;
      try {
        _setStatus('Validating Telegram session...');
        repository = await DataRepository.create();
        final bootstrap = await repository.bootstrapConnectedSession(
          requireTelegramSession:
              authNotifier.hasTelegramSession && !authNotifier.telegramSessionValidatedInProcess,
        );
        oxBootstrapReady = true;
        if (bootstrap.telegramReady) {
          authNotifier.markTelegramSessionValidatedInProcess();
        }
        _setStatus(
          bootstrap.telegramReady
              ? 'Connected to Telegram and OXPlayer API.'
            : 'Connected to server.',
        );
      } on OxBootstrapUnauthorized {
        final apiReachable = await _isApiReachable(hasNetwork: hasNetwork);
        if (apiReachable) {
          await authNotifier.clearSession();
          if (mounted) {
            Navigator.pushReplacement(context, fadeRoute(const AppRouter()));
          }
          return;
        }
        pendingOxApiRecovery = true;
      } on TdlibInteractiveLoginRequired {
        final apiReachable = await _isApiReachable(hasNetwork: hasNetwork);
        if (apiReachable) {
          await authNotifier.clearSession();
          if (mounted) {
            Navigator.pushReplacement(context, fadeRoute(const AppRouter()));
          }
          return;
        }
        pendingOxApiRecovery = true;
      } catch (e, stackTrace) {
        pendingOxApiRecovery = true;
        appLogger.w('Failed to validate OX bootstrap session, continuing with offline fallback', error: e, stackTrace: stackTrace);
      } finally {
        await repository?.dispose();
      }
    }

    if (hasNetwork) {
      _setStatus(t.common.refreshingServers);

      // Refresh servers from API to get updated connection info (IPs may change).
      // If the stored token is invalid (e.g. after removing a Plex profile PIN),
      // redirect to AuthScreen so the user can re-authenticate.
      final refreshResult = await registry.refreshServersFromApi();
      if (refreshResult == ServerRefreshResult.authError) {
        if (oxBootstrapReady) {
          appLogger.w('Plex token rejected while OX bootstrap is valid; continuing without Plex server connections.');
          await registry.clearAllServers();
        } else {
          final apiReachable = await _isApiReachable(hasNetwork: hasNetwork);
          if (!apiReachable && hasPersistedSession) {
            pendingOxApiRecovery = true;
          } else {
            await storage.clearCredentials();
            if (mounted) {
              await context.read<AuthNotifier>().clearSession();
              if (!mounted) return;
              Navigator.pushReplacement(context, fadeRoute(const AppRouter()));
            }
            return;
          }
        }
      }
    }

    _setStatus(t.common.loadingServers);

    // Load all configured servers
    final servers = await registry.getServers();

    if (!mounted) return;

    // No network — skip connection attempts and go straight to offline mode.
    // Important: this must happen before the empty-server redirect so persisted
    // local sessions don't bounce between setup and auth while offline.
    if (!hasNetwork) {
      if (servers.isNotEmpty || hasPersistedSession) {
        _setStatus(t.common.startingOfflineMode);
        await context.read<DownloadProvider>().ensureInitialized();
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          fadeRoute(
            const MainScreen(
              isOfflineMode: true,
                enableOxDiscoverFallback: true,
            ),
          ),
        );
      } else {
        Navigator.pushReplacement(context, fadeRoute(const AppRouter()));
      }
      return;
    }

    if (servers.isEmpty) {
      if (mounted) {
        if (oxBootstrapReady) {
          await context.read<DownloadProvider>().ensureInitialized();
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            fadeRoute(
              const MainScreen(
                isOfflineMode: true,
                showReconnectAction: false,
                offlineStatusLabel: 'Connected to server',
                enableOxDiscoverFallback: true,
              ),
            ),
          );
        } else if (pendingOxApiRecovery) {
          await context.read<DownloadProvider>().ensureInitialized();
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            fadeRoute(
              const MainScreen(
                isOfflineMode: true,
                pendingOxApiRecovery: true,
                enableOxDiscoverFallback: true,
              ),
            ),
          );
        } else if (hasPersistedSession) {
          await context.read<DownloadProvider>().ensureInitialized();
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            fadeRoute(
              const MainScreen(
                isOfflineMode: true,
                enableOxDiscoverFallback: true,
              ),
            ),
          );
        } else {
          Navigator.pushReplacement(context, fadeRoute(const AppRouter()));
        }
      }
      return;
    }

    Sentry.addBreadcrumb(Breadcrumb(message: 'Connecting to ${servers.length} server(s)', category: 'setup'));
    _setStatus(t.common.connectingToServers);

    // Populate per-server status for splash display
    if (mounted) {
      setState(() {
        for (final server in servers) {
          _serverStatus[server.clientIdentifier] = (server.name, null);
        }
      });
    }

    try {
      final result = await ServerConnectionOrchestrator.connectAndInitialize(
        servers: servers,
        multiServerProvider: context.read<MultiServerProvider>(),
        librariesProvider: context.read<LibrariesProvider>(),
        syncService: context.read<OfflineWatchSyncService>(),
        clientIdentifier: storage.getClientIdentifier(),
        onServerStatus: (serverId, success) {
          if (mounted) {
            setState(() {
              final existing = _serverStatus[serverId];
              if (existing != null) {
                _serverStatus[serverId] = (existing.$1, success);
              }
            });
          }
        },
      );

      if (!mounted) return;

      if (result.hasConnections && result.firstClient != null) {
        // Resume any downloads that were interrupted by app kill
        final downloadProvider = context.read<DownloadProvider>();
        downloadProvider.ensureInitialized().then((_) {
          downloadProvider.resumeQueuedDownloads(result.firstClient!);
        });

        Navigator.pushReplacement(context, fadeRoute(MainScreen(client: result.firstClient!)));
      } else {
        _setStatus(t.common.startingOfflineMode);
        await context.read<DownloadProvider>().ensureInitialized();
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          fadeRoute(
            oxBootstrapReady
                ? const MainScreen(
                    isOfflineMode: true,
                    showReconnectAction: false,
                    offlineStatusLabel: 'Connected to server',
                    enableOxDiscoverFallback: true,
                  )
                : MainScreen(
                    isOfflineMode: true,
                    pendingOxApiRecovery: pendingOxApiRecovery,
                    enableOxDiscoverFallback: true,
                  ),
          ),
        );
      }
    } catch (e, stackTrace) {
      appLogger.e('Error during multi-server connection', error: e, stackTrace: stackTrace);

      if (mounted) {
        _setStatus(t.common.startingOfflineMode);
        await context.read<DownloadProvider>().ensureInitialized();
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          fadeRoute(
            oxBootstrapReady
                ? const MainScreen(
                    isOfflineMode: true,
                    showReconnectAction: false,
                    offlineStatusLabel: 'Connected to server',
                    enableOxDiscoverFallback: true,
                  )
                : MainScreen(
                    isOfflineMode: true,
                    pendingOxApiRecovery: pendingOxApiRecovery,
                    enableOxDiscoverFallback: true,
                  ),
          ),
        );
      }
    }
  }

  Widget _buildStatusText(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Text(
        _statusMessage,
        key: ValueKey(_statusMessage),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildServerStatusList(BuildContext context) {
    if (_serverStatus.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    final dimColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    const coralColor = Color(0xFFE5A00D);
    const successColor = Color(0xFF4CAF50);
    const failColor = Color(0xFFEF5350);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _serverStatus.entries.map((entry) {
        final (name, connected) = entry.value;
        final Widget statusIcon;
        if (connected == null) {
          statusIcon = const SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: coralColor),
          );
        } else if (connected) {
          statusIcon = const Icon(Icons.check_circle, size: 14, color: successColor);
        } else {
          statusIcon = const Icon(Icons.cancel, size: 14, color: failColor);
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              statusIcon,
              const SizedBox(width: 8),
              Text(name, style: textTheme.bodySmall?.copyWith(color: dimColor)),
            ],
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    const coralColor = Color(0xFFE5A00D);
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        children: [
          Center(
            child: Image.asset(
              'assets/plezy.png',
              width: 224,
              height: 224,
              filterQuality: FilterQuality.high,
            ),
          ),
          Positioned(
            left: 0, right: 0,
            bottom: MediaQuery.of(context).size.height * 0.5 - 170,
            child: _buildStatusText(context),
          ),
          Positioned(
            left: 0, right: 0,
            top: MediaQuery.of(context).size.height * 0.5 + 180,
            child: Center(
              child: _serverStatus.isEmpty
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: coralColor),
                    )
                  : _buildServerStatusList(context),
            ),
          ),
        ],
      ),
    );
  }
}
