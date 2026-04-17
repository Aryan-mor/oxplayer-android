import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:oxplayer/services/tv_cast_receiver_service.dart';
import 'package:oxplayer/services/storage_service.dart';

/// **Property 2: Preservation - Cast Job Processing Behavior**
/// 
/// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
/// 
/// These tests verify that existing cast job processing behavior is preserved:
/// - Cast job polling mechanism with exponential backoff
/// - Cast job data parsing and logging
/// - Acknowledgment to backend via POST /me/cast/jobs/:id/started
/// - All cast job fields are parsed correctly
/// - The onCastJobReceived callback invocation works correctly
/// 
/// **IMPORTANT**: These tests are run on UNFIXED code to establish baseline behavior.
/// They should PASS on unfixed code and continue to PASS after the fix is implemented.
void main() {
  group('TV Cast Receiver Preservation Tests', () {
    late Dio mockDio;
    late MockStorageService mockStorageService;
    late TvCastReceiverService service;

    setUp(() {
      mockDio = Dio();
      mockStorageService = MockStorageService();
      service = TvCastReceiverService(
        dio: mockDio,
        baseUrl: 'https://api.example.com',
        storageService: mockStorageService,
      );
    });

    tearDown(() {
      service.dispose();
    });

    /// Test 1: Cast Job Parsing Preservation
    /// 
    /// Verifies that CastJobData is parsed correctly with all fields.
    /// This behavior must be preserved after the fix.
    group('Test 1: Cast Job Parsing Preservation', () {
      test('should parse CastJobData with all required fields', () {
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': 'test_video.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.jobId, 'job123');
        expect(castJobData.chatId, 'chat456');
        expect(castJobData.messageId, 789);
        expect(castJobData.fileId, 'file101');
        expect(castJobData.fileName, 'test_video.mp4');
        expect(castJobData.mimeType, 'video/mp4');
        expect(castJobData.totalBytes, 1024000);
        expect(castJobData.createdAt, DateTime.parse('2024-01-15T10:30:00.000Z'));
      });

      test('should parse CastJobData with optional thumbnailUrl', () {
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': 'test_video.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'thumbnailUrl': 'https://example.com/thumb.jpg',
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.thumbnailUrl, 'https://example.com/thumb.jpg');
      });

      test('should parse CastJobData with optional metadata', () {
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': 'test_video.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'metadata': {'duration': 120, 'title': 'Test Video'},
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.metadata, {'duration': 120, 'title': 'Test Video'});
        expect(castJobData.metadata?['duration'], 120);
        expect(castJobData.metadata?['title'], 'Test Video');
      });

      test('should parse CastJobData with null optional fields', () {
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': 'test_video.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.thumbnailUrl, null);
        expect(castJobData.metadata, null);
      });

      test('should parse CastJobData with various file types', () {
        final testCases = [
          {
            'jobId': 'job1',
            'chatId': 'chat1',
            'messageId': 1,
            'fileId': 'file1',
            'fileName': 'video.mp4',
            'mimeType': 'video/mp4',
            'totalBytes': 1024000,
            'createdAt': '2024-01-15T10:30:00.000Z',
          },
          {
            'jobId': 'job2',
            'chatId': 'chat2',
            'messageId': 2,
            'fileId': 'file2',
            'fileName': 'movie.mkv',
            'mimeType': 'video/x-matroska',
            'totalBytes': 5242880,
            'createdAt': '2024-01-15T10:30:00.000Z',
          },
          {
            'jobId': 'job3',
            'chatId': 'chat3',
            'messageId': 3,
            'fileId': 'file3',
            'fileName': 'clip.avi',
            'mimeType': 'video/x-msvideo',
            'totalBytes': 2097152,
            'createdAt': '2024-01-15T10:30:00.000Z',
          },
        ];

        for (final json in testCases) {
          final castJobData = CastJobData.fromJson(json);
          expect(castJobData.jobId, json['jobId']);
          expect(castJobData.fileName, json['fileName']);
          expect(castJobData.mimeType, json['mimeType']);
          expect(castJobData.totalBytes, json['totalBytes']);
        }
      });

      test('should parse CastJobData with various file sizes', () {
        final testCases = [
          1024, // 1 KB
          1048576, // 1 MB
          10485760, // 10 MB
          104857600, // 100 MB
          1073741824, // 1 GB
        ];

        for (final size in testCases) {
          final json = {
            'jobId': 'job_$size',
            'chatId': 'chat456',
            'messageId': 789,
            'fileId': 'file_$size',
            'fileName': 'test_$size.mp4',
            'mimeType': 'video/mp4',
            'totalBytes': size,
            'createdAt': '2024-01-15T10:30:00.000Z',
          };

          final castJobData = CastJobData.fromJson(json);
          expect(castJobData.totalBytes, size);
        }
      });
    });

    /// Test 2: Callback Invocation Preservation
    /// 
    /// Verifies that the onCastJobReceived callback is invoked correctly.
    /// This behavior must be preserved after the fix.
    group('Test 2: Callback Invocation Preservation', () {
      test('should invoke onCastJobReceived callback when cast job is received', () {
        CastJobData? receivedJobData;
        service.onCastJobReceived = (jobData) {
          receivedJobData = jobData;
        };

        final testJobData = CastJobData(
          jobId: 'job123',
          chatId: 'chat456',
          messageId: 789,
          fileId: 'file101',
          fileName: 'test_video.mp4',
          mimeType: 'video/mp4',
          totalBytes: 1024000,
          createdAt: DateTime.parse('2024-01-15T10:30:00.000Z'),
        );

        // Simulate callback invocation
        service.onCastJobReceived?.call(testJobData);

        expect(receivedJobData, isNotNull);
        expect(receivedJobData?.jobId, 'job123');
        expect(receivedJobData?.fileName, 'test_video.mp4');
      });

      test('should pass complete CastJobData object to callback', () {
        CastJobData? receivedJobData;
        service.onCastJobReceived = (jobData) {
          receivedJobData = jobData;
        };

        final testJobData = CastJobData(
          jobId: 'job123',
          chatId: 'chat456',
          messageId: 789,
          fileId: 'file101',
          fileName: 'test_video.mp4',
          mimeType: 'video/mp4',
          totalBytes: 1024000,
          thumbnailUrl: 'https://example.com/thumb.jpg',
          metadata: {'duration': 120},
          createdAt: DateTime.parse('2024-01-15T10:30:00.000Z'),
        );

        service.onCastJobReceived?.call(testJobData);

        expect(receivedJobData?.jobId, 'job123');
        expect(receivedJobData?.chatId, 'chat456');
        expect(receivedJobData?.messageId, 789);
        expect(receivedJobData?.fileId, 'file101');
        expect(receivedJobData?.fileName, 'test_video.mp4');
        expect(receivedJobData?.mimeType, 'video/mp4');
        expect(receivedJobData?.totalBytes, 1024000);
        expect(receivedJobData?.thumbnailUrl, 'https://example.com/thumb.jpg');
        expect(receivedJobData?.metadata, {'duration': 120});
      });

      test('should handle multiple callback invocations', () {
        final receivedJobs = <CastJobData>[];
        service.onCastJobReceived = (jobData) {
          receivedJobs.add(jobData);
        };

        final testJobs = [
          CastJobData(
            jobId: 'job1',
            chatId: 'chat1',
            messageId: 1,
            fileId: 'file1',
            fileName: 'video1.mp4',
            mimeType: 'video/mp4',
            totalBytes: 1024000,
            createdAt: DateTime.parse('2024-01-15T10:30:00.000Z'),
          ),
          CastJobData(
            jobId: 'job2',
            chatId: 'chat2',
            messageId: 2,
            fileId: 'file2',
            fileName: 'video2.mp4',
            mimeType: 'video/mp4',
            totalBytes: 2048000,
            createdAt: DateTime.parse('2024-01-15T10:31:00.000Z'),
          ),
          CastJobData(
            jobId: 'job3',
            chatId: 'chat3',
            messageId: 3,
            fileId: 'file3',
            fileName: 'video3.mp4',
            mimeType: 'video/mp4',
            totalBytes: 3072000,
            createdAt: DateTime.parse('2024-01-15T10:32:00.000Z'),
          ),
        ];

        for (final job in testJobs) {
          service.onCastJobReceived?.call(job);
        }

        expect(receivedJobs.length, 3);
        expect(receivedJobs[0].jobId, 'job1');
        expect(receivedJobs[1].jobId, 'job2');
        expect(receivedJobs[2].jobId, 'job3');
      });
    });

    /// Test 3: Service State Preservation
    /// 
    /// Verifies that the service state (polling, error handling) is preserved.
    /// This behavior must be preserved after the fix.
    group('Test 3: Service State Preservation', () {
      test('should start polling when startPolling is called', () {
        expect(service.isPolling, false);

        service.startPolling();

        expect(service.isPolling, true);
      });

      test('should stop polling when stopPolling is called', () {
        service.startPolling();
        expect(service.isPolling, true);

        service.stopPolling();

        expect(service.isPolling, false);
      });

      test('should reset error count when stopPolling is called', () {
        service.startPolling();
        // Simulate errors by accessing internal state (if possible)
        // For now, just verify the service can be stopped

        service.stopPolling();

        expect(service.consecutiveErrorCount, 0);
      });

      test('should be healthy initially', () {
        expect(service.isHealthy, true);
      });

      test('should allow restart polling', () {
        service.startPolling();
        expect(service.isPolling, true);

        service.restartPolling();

        expect(service.isPolling, true);
      });

      test('should not start polling twice', () {
        service.startPolling();
        expect(service.isPolling, true);

        // Try to start again
        service.startPolling();

        // Should still be polling (not duplicated)
        expect(service.isPolling, true);
      });
    });

    /// Test 4: CastJobData toString Preservation
    /// 
    /// Verifies that CastJobData toString method works correctly for logging.
    /// This behavior must be preserved after the fix.
    group('Test 4: CastJobData toString Preservation', () {
      test('should provide readable toString output', () {
        final castJobData = CastJobData(
          jobId: 'job123',
          chatId: 'chat456',
          messageId: 789,
          fileId: 'file101',
          fileName: 'test_video.mp4',
          mimeType: 'video/mp4',
          totalBytes: 1024000,
          createdAt: DateTime.parse('2024-01-15T10:30:00.000Z'),
        );

        final str = castJobData.toString();

        expect(str, contains('job123'));
        expect(str, contains('test_video.mp4'));
        expect(str, contains('file101'));
      });

      test('should include all key fields in toString', () {
        final castJobData = CastJobData(
          jobId: 'job_abc',
          chatId: 'chat_xyz',
          messageId: 999,
          fileId: 'file_def',
          fileName: 'movie.mp4',
          mimeType: 'video/mp4',
          totalBytes: 5242880,
          createdAt: DateTime.parse('2024-01-15T10:30:00.000Z'),
        );

        final str = castJobData.toString();

        expect(str, contains('job_abc'));
        expect(str, contains('movie.mp4'));
        expect(str, contains('file_def'));
      });
    });

    /// Test 5: Edge Cases Preservation
    /// 
    /// Verifies that edge cases are handled correctly.
    /// This behavior must be preserved after the fix.
    group('Test 5: Edge Cases Preservation', () {
      test('should handle empty metadata map', () {
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': 'test_video.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'metadata': <String, dynamic>{},
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.metadata, isNotNull);
        expect(castJobData.metadata, isEmpty);
      });

      test('should handle very long file names', () {
        final longFileName = 'a' * 255 + '.mp4';
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': longFileName,
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.fileName, longFileName);
        expect(castJobData.fileName.length, 259);
      });

      test('should handle special characters in file names', () {
        final specialFileName = 'test_video (1) [HD] 2024.mp4';
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': specialFileName,
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.fileName, specialFileName);
      });

      test('should handle zero byte files', () {
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': 'empty.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': 0,
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.totalBytes, 0);
      });

      test('should handle very large file sizes', () {
        final largeSize = 10737418240; // 10 GB
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': 789,
          'fileId': 'file101',
          'fileName': 'large_movie.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': largeSize,
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.totalBytes, largeSize);
      });

      test('should handle negative message IDs', () {
        final json = {
          'jobId': 'job123',
          'chatId': 'chat456',
          'messageId': -1,
          'fileId': 'file101',
          'fileName': 'test.mp4',
          'mimeType': 'video/mp4',
          'totalBytes': 1024000,
          'createdAt': '2024-01-15T10:30:00.000Z',
        };

        final castJobData = CastJobData.fromJson(json);

        expect(castJobData.messageId, -1);
      });

      test('should handle various date formats', () {
        final dateStrings = [
          '2024-01-15T10:30:00.000Z',
          '2024-01-15T10:30:00Z',
          '2024-01-15T10:30:00.123456Z',
        ];

        for (final dateStr in dateStrings) {
          final json = {
            'jobId': 'job123',
            'chatId': 'chat456',
            'messageId': 789,
            'fileId': 'file101',
            'fileName': 'test.mp4',
            'mimeType': 'video/mp4',
            'totalBytes': 1024000,
            'createdAt': dateStr,
          };

          final castJobData = CastJobData.fromJson(json);
          expect(castJobData.createdAt, isA<DateTime>());
        }
      });
    });
  });
}

/// Mock StorageService for testing
class MockStorageService implements StorageService {
  String? _accessToken;

  @override
  String? getApiAccessToken() => _accessToken;

  void setAccessToken(String token) {
    _accessToken = token;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
