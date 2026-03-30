import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/debug/app_debug_log.dart';
import 'entities.dart';

/// Extension to provide a consistent retry mechanism for Isar operations
/// that fail with MdbxError (11) "Try again" (EAGAIN), common on Android TV.
extension IsarRetryExtension on Isar {
  Future<T> runWithRetry<T>(Future<T> Function() operation, {String? debugName}) async {
    const maxAttempts = 25;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await operation();
      } catch (e) {
        final errStr = e.toString();
        final isRetryable = errStr.contains('MdbxError (11)') || errStr.contains('Try again');
        
        if (!isRetryable || attempt == maxAttempts) {
          if (debugName != null) {
            AppDebugLog.instance.log('Isar[$debugName]: Persistent failure after $maxAttempts attempts: $e');
          }
          rethrow;
        }

        final backoffMs = math.min(attempt * 200, 2000);
        if (attempt % 5 == 0) {
          AppDebugLog.instance.log(
            'Isar${debugName != null ? "[$debugName]" : ""}: Retrying ($attempt/$maxAttempts) after ${backoffMs}ms...',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
      }
    }
    throw StateError('Isar retry exhausted');
  }
}

/// Ensures the MDBX environment is fully ready after Isar.open.
/// On Android TV, the slower eMMC storage + kernel mmap handling can cause
/// reads to fail with EAGAIN immediately after open even though open succeeded.
Future<void> _warmUpMdbx(Isar isar) async {
  AppDebugLog.instance.log('Isar: Warming up MDBX environment...');
  for (var attempt = 1; attempt <= 10; attempt++) {
    try {
      await isar.mediaItems.count();
      AppDebugLog.instance.log('Isar: MDBX warm-up complete (attempt $attempt).');
      return;
    } catch (e) {
      final backoff = 300 * attempt;
      if (attempt % 3 == 0) {
        AppDebugLog.instance.log(
          'Isar: MDBX warm-up attempt $attempt/10 failed, retrying in ${backoff}ms...',
        );
      }
      await Future<void>.delayed(Duration(milliseconds: backoff));
    }
  }
  AppDebugLog.instance.log('Isar: MDBX warm-up did not fully succeed, continuing.');
}

final isarProvider = FutureProvider<Isar>((ref) async {
  // Use getApplicationDocumentsDirectory because getApplicationSupportDirectory
  // often has filesystem locking issues on Android TV devices.
  final dir = await getApplicationDocumentsDirectory();
  
  final existing = Isar.instanceNames.contains('telecima')
      ? Isar.getInstance('telecima')
      : null;
  if (existing != null) {
    return existing;
  }

  const maxAttempts = 10;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      AppDebugLog.instance.log('Isar: Opening database (attempt $attempt)');
      final isar = await Isar.open(
        [
          MediaSourceSchema,
          MediaItemSchema,
          MediaVariantSchema,
          SyncCheckpointSchema,
          MediaDownloadSchema,
          TelegramSessionSchema,
          MediaSeasonSchema,
          MediaEpisodeSchema,
        ],
        directory: dir.path,
        name: 'telecima',
        inspector: kDebugMode && !Platform.isAndroid,
        compactOnLaunch: const CompactCondition(
          minRatio: 2.0,
          minFileSize: 524288,
        ),
      );
      AppDebugLog.instance.log('Isar: Successfully opened.');

      if (Platform.isAndroid) {
        await _warmUpMdbx(isar);
      }

      return isar;
    } catch (e) {
      final errStr = e.toString();
      final isRetryable = errStr.contains('MdbxError (11)') || errStr.contains('Try again');
      
      if (!isRetryable || attempt == maxAttempts) {
        AppDebugLog.instance.log('Isar: Open failed: $e');
        rethrow;
      }

      final backoffMs = attempt * 300;
      AppDebugLog.instance.log('Isar: Open busy, waiting ${backoffMs}ms...');
      await Future<void>.delayed(Duration(milliseconds: backoffMs));

      final alreadyOpen = Isar.instanceNames.contains('telecima')
          ? Isar.getInstance('telecima')
          : null;
      if (alreadyOpen != null) return alreadyOpen;
    }
  }

  throw StateError('Failed to initialize Isar');
});
