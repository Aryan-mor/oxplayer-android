import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../exceptions/cast_exception.dart';
import '../models/cast_job.dart';
import '../utils/app_logger.dart';
import 'settings_service.dart';

/// Service for managing TV cast receiver operations.
///
/// This service handles:
/// - Long polling for cast jobs from the backend
/// - Exponential backoff on network errors
/// - Cast toggle state management
/// - Foreground service lifecycle management
/// - Cast job claiming and processing
///
/// The service extends [ChangeNotifier] to notify listeners of state changes
/// such as polling status and cast enabled state.
class CastReceiverService extends ChangeNotifier {
  final Dio _dio;
  final String _baseUrl;
  final SettingsService _settingsService;

  /// Whether the service is currently polling for cast jobs.
  bool _isPolling = false;

  /// Whether cast receiver functionality is enabled.
  bool _isCastEnabled = false;

  /// Timer for scheduling the next poll attempt (used during backoff).
  Timer? _pollTimer;

  /// Current backoff delay in seconds (doubles on each error, resets on success).
  int _backoffSeconds = 1;

  /// Maximum backoff delay in seconds.
  static const int _maxBackoffSeconds = 60;

  /// Long polling timeout in seconds.
  static const int _pollTimeoutSeconds = 30;

  /// HTTP receive timeout (slightly longer than poll timeout to account for network latency).
  static const int _receiveTimeoutSeconds = 35;

  /// Creates a new [CastReceiverService] instance.
  ///
  /// [dio] - The Dio HTTP client for making API requests.
  /// [baseUrl] - The base URL of the backend API.
  /// [settingsService] - The settings service for persisting cast toggle state.
  ///
  /// The service automatically starts polling if cast is enabled in settings.
  CastReceiverService({
    required Dio dio,
    required String baseUrl,
    required SettingsService settingsService,
  })  : _dio = dio,
        _baseUrl = baseUrl,
        _settingsService = settingsService {
    _isCastEnabled = _settingsService.getCastToggleEnabled();
    if (_isCastEnabled) {
      startPolling();
    }
  }

  /// Whether cast receiver functionality is currently enabled.
  bool get isCastEnabled => _isCastEnabled;

  /// Whether the service is actively polling for cast jobs.
  bool get isPolling => _isPolling;

  /// Enables or disables cast receiver functionality.
  ///
  /// When enabled, starts the foreground service and begins polling.
  /// When disabled, stops the foreground service and cancels polling.
  ///
  /// The state is persisted to settings and listeners are notified.
  ///
  /// [enabled] - Whether to enable or disable cast receiver functionality.
  Future<void> setCastEnabled(bool enabled) async {
    _isCastEnabled = enabled;
    await _settingsService.setCastToggleEnabled(enabled);

    if (enabled) {
      await startPolling();
    } else {
      await stopPolling();
    }

    notifyListeners();
  }

  /// Starts the foreground service and begins polling for cast jobs.
  ///
  /// If already polling, this method does nothing.
  /// Resets the backoff delay and starts the polling loop.
  Future<void> startPolling() async {
    if (_isPolling) return;

    _isPolling = true;
    _backoffSeconds = 1;
    await _startForegroundService();
    _poll();
    notifyListeners();
  }

  /// Stops the foreground service and cancels all polling operations.
  ///
  /// If not currently polling, this method does nothing.
  /// Cancels any pending poll timers and stops the foreground service.
  Future<void> stopPolling() async {
    if (!_isPolling) return;

    _isPolling = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _stopForegroundService();
    notifyListeners();
  }

  /// Performs a single long polling request for cast jobs.
  ///
  /// This method:
  /// - Makes a GET request to /me/cast/jobs/claim with a 30s timeout
  /// - Handles successful job delivery (HTTP 200)
  /// - Handles no job available (HTTP 204)
  /// - Implements exponential backoff on network errors
  /// - Stops polling on authentication errors (HTTP 401)
  ///
  /// The method recursively calls itself to maintain continuous polling.
  Future<void> _poll() async {
    if (!_isPolling) return;

    try {
      final response = await _dio.get(
        '$_baseUrl/me/cast/jobs/claim',
        queryParameters: {'timeout': _pollTimeoutSeconds},
        options: Options(
          receiveTimeout: const Duration(seconds: _receiveTimeoutSeconds),
        ),
      );

      if (response.statusCode == 200) {
        // Job received - reset backoff and handle the job
        _backoffSeconds = 1;
        final job = CastJob.fromJson(response.data);
        await _handleCastJob(job);
        // Immediately poll again for the next job
        _poll();
      } else if (response.statusCode == 204) {
        // No job available - reset backoff and poll again immediately
        _backoffSeconds = 1;
        _poll();
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // Authentication error - stop polling
        appLogger.e('Cast polling: Auth error, stopping');
        await stopPolling();
        return;
      }

      // Network error - retry with exponential backoff
      appLogger.w('Cast polling error: ${e.message}');
      _pollTimer = Timer(Duration(seconds: _backoffSeconds), _poll);
      _backoffSeconds = (_backoffSeconds * 2).clamp(1, _maxBackoffSeconds);
    }
  }

  /// Handles a received cast job.
  ///
  /// This is a placeholder method that will be implemented in Task 10.2.
  /// It should:
  /// - Show a "Cast in progress..." notification
  /// - Hydrate the peer connection
  /// - Stop current playback
  /// - Open the player with the hydrated metadata
  /// - Acknowledge job started
  ///
  /// [job] - The cast job to handle.
  Future<void> _handleCastJob(CastJob job) async {
    // TODO: Implement in Task 10.2
    appLogger.i('Received cast job: ${job.jobId} for file: ${job.fileName}');
  }

  /// Starts the Android foreground service to prevent Doze mode.
  ///
  /// This is a placeholder method that will be implemented when the
  /// CastForegroundService is created in a later task.
  Future<void> _startForegroundService() async {
    // TODO: Implement when CastForegroundService is available
    // await CastForegroundService.start();
    appLogger.d('Cast foreground service start requested (not yet implemented)');
  }

  /// Stops the Android foreground service.
  ///
  /// This is a placeholder method that will be implemented when the
  /// CastForegroundService is created in a later task.
  Future<void> _stopForegroundService() async {
    // TODO: Implement when CastForegroundService is available
    // await CastForegroundService.stop();
    appLogger.d('Cast foreground service stop requested (not yet implemented)');
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
