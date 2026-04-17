import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../services/auth_debug_service.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';

/// TV Cast Receiver Service
/// 
/// Polls the backend for incoming cast jobs and handles them.
/// This service should only run on TV devices.
class TvCastReceiverService {
  final Dio _dio;
  final String _baseUrl;
  final StorageService _storageService;
  
  Timer? _pollingTimer;
  bool _isPolling = false;
  bool _isProcessingJob = false;
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 5;
  static const Duration _basePollingInterval = Duration(seconds: 15);
  static const Duration _errorBackoffInterval = Duration(seconds: 120);
  
  /// Callback when a cast job is received
  Function(CastJobData)? onCastJobReceived;
  
  TvCastReceiverService({
    required Dio dio,
    required String baseUrl,
    required StorageService storageService,
  })  : _dio = dio,
        _baseUrl = baseUrl,
        _storageService = storageService;

  /// Start polling for cast jobs
  void startPolling() {
    if (_isPolling) {
      appLogger.w('[Cast] TV receiver already polling');
      return;
    }
    
    _isPolling = true;
    _consecutiveErrors = 0;
    appLogger.i('[Cast] TV receiver started polling for cast jobs');
    castDebugSuccess('TV receiver started polling for cast jobs');
    
    // Start immediate poll, then continue with timer
    _pollForCastJobs();
  }
  
  void _scheduleNextPoll() {
    if (!_isPolling) return;
    
    // Use exponential backoff if there are consecutive errors
    final interval = _consecutiveErrors >= _maxConsecutiveErrors 
        ? _errorBackoffInterval 
        : _basePollingInterval;
    
    if (_consecutiveErrors >= _maxConsecutiveErrors) {
      appLogger.d('[Cast] TV receiver: Using backoff interval due to errors (${interval.inSeconds}s)');
    }
    
    _pollingTimer = Timer(interval, () {
      if (_isPolling && !_isProcessingJob) {
        _pollForCastJobs();
      }
    });
  }
  
  /// Stop polling for cast jobs
  void stopPolling() {
    if (!_isPolling) return;
    
    _isPolling = false;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _consecutiveErrors = 0;
    
    appLogger.i('[Cast] TV receiver stopped polling');
    castDebugInfo('TV receiver stopped polling');
  }
  
  /// Check if the service is healthy (not too many consecutive errors)
  bool get isHealthy => _consecutiveErrors < _maxConsecutiveErrors;
  
  /// Check if the service is currently polling
  bool get isPolling => _isPolling;
  
  /// Get current error count for debugging
  int get consecutiveErrorCount => _consecutiveErrors;
  
  /// Poll for cast jobs using long polling
  Future<void> _pollForCastJobs() async {
    if (!_isPolling || _isProcessingJob) return;
    
    final accessToken = _storageService.getApiAccessToken()?.trim() ?? '';
    if (accessToken.isEmpty) {
      appLogger.w('[Cast] TV receiver: No access token available');
      _consecutiveErrors++;
      _scheduleNextPoll();
      return;
    }
    
    // Run the network request in background without blocking the main thread
    unawaited(_performBackgroundPoll(accessToken));
  }
  
  /// Perform the actual polling in background without blocking the main thread
  Future<void> _performBackgroundPoll(String accessToken) async {
    try {
      appLogger.d('[Cast] TV receiver: Polling for cast jobs...');
      castDebugInfo('TV receiver: Polling for cast jobs...');
      
      // Use shorter polling with 5 second timeout to prevent ANR issues
      final response = await _dio.get(
        '$_baseUrl/me/cast/jobs/claim',
        queryParameters: {
          'timeout': 5, // Shorter 5 second polling to prevent blocking
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $accessToken',
          },
          // Set shorter timeout to prevent ANR
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      
      // Reset error count on successful request
      _consecutiveErrors = 0;
      
      if (response.statusCode == 200) {
        // Cast job received!
        final jobData = CastJobData.fromJson(response.data);
        
        appLogger.i('[Cast] TV receiver: Cast job received - ${jobData.fileName}');
        castDebugSuccess('TV receiver: Cast job received - ${jobData.fileName}');
        
        // Handle cast job asynchronously without blocking
        unawaited(_handleCastJob(jobData));
      } else if (response.statusCode == 204) {
        // No cast job available (timeout)
        appLogger.d('[Cast] TV receiver: No cast jobs available (timeout)');
        castDebugInfo('TV receiver: No cast jobs available (timeout)');
      }
    } on DioException catch (e) {
      _consecutiveErrors++;
      
      if (e.type == DioExceptionType.receiveTimeout) {
        // Short polling timeout - this is normal, don't count as error
        _consecutiveErrors = 0;
        appLogger.d('[Cast] TV receiver: Short polling timeout (normal)');
        castDebugInfo('TV receiver: Short polling timeout (normal)');
      } else if (e.response?.statusCode == 401) {
        // Authentication error - this is serious, log it prominently
        appLogger.e('[Cast] TV receiver: Authentication error - token may be invalid', error: e);
        castDebugError('TV receiver: Authentication error - token may be invalid');
        
        // If too many auth errors, use extended backoff
        if (_consecutiveErrors >= _maxConsecutiveErrors) {
          appLogger.w('[Cast] TV receiver: Too many authentication errors ($_consecutiveErrors), using extended backoff');
          castDebugError('TV receiver: Too many authentication errors, using extended backoff');
        }
      } else {
        appLogger.e('[Cast] TV receiver: Network error polling for cast jobs: ${e.message}', error: e);
        castDebugError('TV receiver: Network error polling for cast jobs: ${e.message}');
        
        // If too many consecutive errors, log warning about backoff
        if (_consecutiveErrors >= _maxConsecutiveErrors) {
          appLogger.w('[Cast] TV receiver: Too many consecutive errors ($_consecutiveErrors), using backoff interval');
          castDebugError('TV receiver: Too many consecutive errors, using slower polling');
        }
      }
    } catch (e) {
      _consecutiveErrors++;
      appLogger.e('[Cast] TV receiver: Unexpected error polling for cast jobs', error: e);
      castDebugError('TV receiver: Unexpected error polling for cast jobs: $e');
    } finally {
      // Always schedule next poll, even if there was an error
      _scheduleNextPoll();
    }
  }
  
  /// Handle received cast job
  Future<void> _handleCastJob(CastJobData jobData) async {
    _isProcessingJob = true;
    
    try {
      appLogger.i('[Cast] TV receiver: Processing cast job ${jobData.jobId}');
      castDebugInfo('TV receiver: Processing cast job ${jobData.jobId}');
      castDebugInfo('  - File: ${jobData.fileName}');
      castDebugInfo('  - FileId: ${jobData.fileId}');
      castDebugInfo('  - ChatId: ${jobData.chatId}');
      castDebugInfo('  - MessageId: ${jobData.messageId}');
      castDebugInfo('  - MimeType: ${jobData.mimeType}');
      castDebugInfo('  - Size: ${jobData.totalBytes} bytes');
      castDebugInfo('  - Thumbnail: ${jobData.thumbnailUrl ?? "none"}');
      castDebugInfo('  - Metadata: ${jobData.metadata}');
      
      // Call the callback if set
      if (onCastJobReceived != null) {
        onCastJobReceived!(jobData);
      } else {
        appLogger.w('[Cast] TV receiver: No cast job handler set - job ignored');
      }
      
      // Acknowledge that playback started (idempotent)
      await _acknowledgePlaybackStarted(jobData.jobId);
      
    } catch (e) {
      appLogger.e('[Cast] TV receiver: Error processing cast job ${jobData.jobId}', error: e);
      castDebugError('TV receiver: Error processing cast job ${jobData.jobId}: $e');
    } finally {
      _isProcessingJob = false;
    }
  }
  
  /// Acknowledge that playback has started
  Future<void> _acknowledgePlaybackStarted(String jobId) async {
    final accessToken = _storageService.getApiAccessToken()?.trim() ?? '';
    if (accessToken.isEmpty) return;
    
    try {
      await _dio.post(
        '$_baseUrl/me/cast/jobs/$jobId/started',
        options: Options(
          headers: {
            'Authorization': 'Bearer $accessToken',
          },
        ),
      );
      
      appLogger.i('[Cast] TV receiver: Acknowledged playback started for job $jobId');
      castDebugSuccess('TV receiver: Acknowledged playback started for job $jobId');
    } catch (e) {
      appLogger.w('[Cast] TV receiver: Failed to acknowledge playback started for job $jobId', error: e);
    }
  }
  
  /// Restart polling (useful for recovery after errors)
  void restartPolling() {
    stopPolling();
    startPolling();
  }
  
  /// Dispose resources
  void dispose() {
    stopPolling();
  }
}

/// Cast job data received from the backend
class CastJobData {
  final String jobId;
  final String chatId;
  final int messageId;
  final String fileId;
  final String fileName;
  final String mimeType;
  final int totalBytes;
  final String? thumbnailUrl;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  
  CastJobData({
    required this.jobId,
    required this.chatId,
    required this.messageId,
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.totalBytes,
    this.thumbnailUrl,
    this.metadata,
    required this.createdAt,
  });
  
  factory CastJobData.fromJson(Map<String, dynamic> json) {
    return CastJobData(
      jobId: json['jobId'] as String,
      chatId: json['chatId'] as String,
      messageId: json['messageId'] as int,
      fileId: json['fileId'] as String,
      fileName: json['fileName'] as String,
      mimeType: json['mimeType'] as String,
      totalBytes: json['totalBytes'] as int,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
  
  @override
  String toString() {
    return 'CastJobData(jobId: $jobId, fileName: $fileName, fileId: $fileId)';
  }
}