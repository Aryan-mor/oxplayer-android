import 'package:flutter_test/flutter_test.dart';
import 'package:oxplayer/models/cast_job.dart';

void main() {
  group('CastJob', () {
    test('should create CastJob from JSON', () {
      final json = {
        'jobId': 'job123',
        'chatId': 'chat456',
        'messageId': 789,
        'fileId': 'file101',
        'fileName': 'test_video.mp4',
        'mimeType': 'video/mp4',
        'totalBytes': 1024000,
        'thumbnailUrl': 'https://example.com/thumb.jpg',
        'metadata': {'duration': 120},
        'createdAt': '2024-01-15T10:30:00.000Z',
      };

      final castJob = CastJob.fromJson(json);

      expect(castJob.jobId, 'job123');
      expect(castJob.chatId, 'chat456');
      expect(castJob.messageId, 789);
      expect(castJob.fileId, 'file101');
      expect(castJob.fileName, 'test_video.mp4');
      expect(castJob.mimeType, 'video/mp4');
      expect(castJob.totalBytes, 1024000);
      expect(castJob.thumbnailUrl, 'https://example.com/thumb.jpg');
      expect(castJob.metadata, {'duration': 120});
      expect(castJob.createdAt, DateTime.parse('2024-01-15T10:30:00.000Z'));
    });

    test('should create CastJob from JSON with null optional fields', () {
      final json = {
        'jobId': 'job123',
        'chatId': 'chat456',
        'messageId': 789,
        'fileId': 'file101',
        'fileName': 'test_audio.mp3',
        'mimeType': 'audio/mp3',
        'totalBytes': 512000,
        'createdAt': '2024-01-15T10:30:00.000Z',
      };

      final castJob = CastJob.fromJson(json);

      expect(castJob.jobId, 'job123');
      expect(castJob.thumbnailUrl, null);
      expect(castJob.metadata, null);
    });

    test('should convert CastJob to JSON', () {
      final castJob = CastJob(
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

      final json = castJob.toJson();

      expect(json['jobId'], 'job123');
      expect(json['chatId'], 'chat456');
      expect(json['messageId'], 789);
      expect(json['fileId'], 'file101');
      expect(json['fileName'], 'test_video.mp4');
      expect(json['mimeType'], 'video/mp4');
      expect(json['totalBytes'], 1024000);
      expect(json['thumbnailUrl'], 'https://example.com/thumb.jpg');
      expect(json['metadata'], {'duration': 120});
      expect(json['createdAt'], '2024-01-15T10:30:00.000Z');
    });

    test('should handle round-trip JSON serialization', () {
      final originalJson = {
        'jobId': 'job123',
        'chatId': 'chat456',
        'messageId': 789,
        'fileId': 'file101',
        'fileName': 'test_video.mp4',
        'mimeType': 'video/mp4',
        'totalBytes': 1024000,
        'thumbnailUrl': 'https://example.com/thumb.jpg',
        'metadata': {'duration': 120},
        'createdAt': '2024-01-15T10:30:00.000Z',
      };

      final castJob = CastJob.fromJson(originalJson);
      final serializedJson = castJob.toJson();

      expect(serializedJson['jobId'], originalJson['jobId']);
      expect(serializedJson['chatId'], originalJson['chatId']);
      expect(serializedJson['messageId'], originalJson['messageId']);
      expect(serializedJson['fileId'], originalJson['fileId']);
      expect(serializedJson['fileName'], originalJson['fileName']);
      expect(serializedJson['mimeType'], originalJson['mimeType']);
      expect(serializedJson['totalBytes'], originalJson['totalBytes']);
      expect(serializedJson['thumbnailUrl'], originalJson['thumbnailUrl']);
      expect(serializedJson['metadata'], originalJson['metadata']);
      expect(serializedJson['createdAt'], originalJson['createdAt']);
    });
  });
}
