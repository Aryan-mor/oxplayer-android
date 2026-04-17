import 'package:dio/dio.dart';

import '../exceptions/cast_exception.dart';
import '../services/auth_debug_service.dart';
import '../utils/app_logger.dart';

/// Service for managing TV cast operations.
///
/// Handles creating cast jobs, tracking active casts, and managing cast state.
/// This service communicates with the backend API to initiate casting operations
/// and maintains an in-memory map of active cast jobs.
class CastService {
  final Dio _dio;
  final String _baseUrl;

  /// Track active cast jobs to disable button during casting.
  /// Maps fileId -> jobId for quick lookup.
  final Map<String, String> _activeCastJobs = {};

  /// Creates a new [CastService] instance.
  ///
  /// [dio] - The Dio HTTP client for making API requests.
  /// [baseUrl] - The base URL of the backend API.
  CastService({
    required Dio dio,
    required String baseUrl,
  })  : _dio = dio,
        _baseUrl = baseUrl;

  /// Creates a new cast job on the backend.
  ///
  /// Sends a POST request to `/me/cast/jobs` with the provided parameters.
  /// On success, tracks the job in [_activeCastJobs] and returns the jobId.
  ///
  /// Parameters:
  /// - [chatId] - The Telegram chat ID containing the media
  /// - [messageId] - The message ID within the chat
  /// - [fileId] - The unique file identifier
  /// - [fileName] - The name of the file being cast
  /// - [mimeType] - The MIME type of the file
  /// - [totalBytes] - The total size of the file in bytes
  /// - [thumbnailUrl] - Optional URL to a thumbnail image
  /// - [metadata] - Optional additional metadata
  /// - [accessToken] - The API access token for authentication
  ///
  /// Returns the jobId string on success.
  ///
  /// Throws [CastException] if the request fails.
  Future<String> createCastJob({
    required String chatId,
    required int messageId,
    required String fileId,
    required String fileName,
    required String mimeType,
    required int totalBytes,
    String? thumbnailUrl,
    Map<String, dynamic>? metadata,
    required String accessToken,
  }) async {
    appLogger.d('[Cast] Creating cast job: fileName=$fileName, fileId=$fileId, mimeType=$mimeType, size=$totalBytes bytes');
    castDebugInfo('Creating cast job: fileName=$fileName, fileId=$fileId, mimeType=$mimeType, size=$totalBytes bytes');
    
    try {
      final response = await _dio.post(
        '$_baseUrl/me/cast/jobs',
        data: {
          'chatId': chatId,
          'messageId': messageId,
          'fileId': fileId,
          'fileName': fileName,
          'mimeType': mimeType,
          'totalBytes': totalBytes,
          if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
          if (metadata != null) 'metadata': metadata,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $accessToken',
          },
        ),
      );

      if (response.statusCode == 201) {
        final jobId = response.data['jobId'] as String;
        _activeCastJobs[fileId] = jobId;
        appLogger.i('[Cast] Cast job created successfully: jobId=$jobId, fileId=$fileId');
        castDebugSuccess('Cast job created successfully: jobId=$jobId, fileId=$fileId');
        return jobId;
      }

      appLogger.e('[Cast] Failed to create cast job: statusCode=${response.statusCode}');
      castDebugError('Failed to create cast job: statusCode=${response.statusCode}');
      throw CastException(
        'Failed to create cast job: ${response.statusCode}',
      );
    } on DioException catch (e) {
      appLogger.e('[Cast] Network error creating cast job: ${e.message}', error: e);
      castDebugError('Network error creating cast job: ${e.message}');
      throw CastException(
        'Network error while creating cast job: ${e.message}',
        e,
      );
    } catch (e) {
      appLogger.e('[Cast] Unexpected error creating cast job', error: e);
      castDebugError('Unexpected error creating cast job: $e');
      throw CastException(
        'Unexpected error while creating cast job',
        e,
      );
    }
  }

  /// Checks if a file is currently being cast.
  ///
  /// [fileId] - The file identifier to check.
  ///
  /// Returns true if the file has an active cast job, false otherwise.
  bool isCasting(String fileId) {
    final isCasting = _activeCastJobs.containsKey(fileId);
    appLogger.d('[Cast] Checking if file is casting: fileId=$fileId, isCasting=$isCasting');
    return isCasting;
  }

  /// Clears the cast job for a specific file.
  ///
  /// This should be called when casting completes or is cancelled.
  ///
  /// [fileId] - The file identifier to clear from active jobs.
  void clearCastJob(String fileId) {
    final jobId = _activeCastJobs[fileId];
    _activeCastJobs.remove(fileId);
    appLogger.d('[Cast] Cleared cast job: fileId=$fileId, jobId=$jobId');
  }

  /// Gets the jobId for a specific file, if it exists.
  ///
  /// [fileId] - The file identifier to look up.
  ///
  /// Returns the jobId if found, null otherwise.
  String? getJobId(String fileId) => _activeCastJobs[fileId];

  /// Clears all active cast jobs.
  ///
  /// This can be used when logging out or resetting the app state.
  void clearAllCastJobs() {
    final count = _activeCastJobs.length;
    _activeCastJobs.clear();
    appLogger.i('[Cast] Cleared all cast jobs: count=$count');
    castDebugInfo('Cleared all cast jobs: count=$count');
  }
}
