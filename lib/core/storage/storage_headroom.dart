import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _kChannel = MethodChannel('oxplayer/storage_space');
const int kStorageCleanupLowBytes = 200 * 1024 * 1024;
const int kStorageCleanupResumeBytes = 350 * 1024 * 1024;
const Duration kStorageCleanupPause = Duration(milliseconds: 600);
bool _cleanupMode = false;

/// Sum of usable bytes on distinct volumes the app may write to (Android native).
/// Returns null on non-Android or if the platform call fails.
Future<int?> queryWritableVolumesFreeBytes() async {
  if (!Platform.isAndroid) return null;
  try {
    final raw =
        await _kChannel.invokeMethod<dynamic>('getWritableVolumesFreeBytes');
    if (raw is! Map) return null;
    final n = raw['totalFreeBytes'];
    if (n is int) return n;
    if (n is num) return n.toInt();
  } catch (_) {}
  return null;
}

class StorageCleanupDecision {
  const StorageCleanupDecision({
    required this.freeBytes,
    required this.cleanupMode,
    required this.enteredNow,
  });

  final int? freeBytes;
  final bool cleanupMode;
  final bool enteredNow;
}

/// Hysteresis-based cleanup mode:
/// - enter at <= [kStorageCleanupLowBytes]
/// - stay in cleanup mode until >= [kStorageCleanupResumeBytes]
Future<StorageCleanupDecision> queryStorageCleanupDecision() async {
  final free = await queryWritableVolumesFreeBytes();
  if (free == null) {
    return StorageCleanupDecision(
      freeBytes: null,
      cleanupMode: _cleanupMode,
      enteredNow: false,
    );
  }

  final wasCleanup = _cleanupMode;
  if (!_cleanupMode && free <= kStorageCleanupLowBytes) {
    _cleanupMode = true;
  } else if (_cleanupMode && free >= kStorageCleanupResumeBytes) {
    _cleanupMode = false;
  }

  return StorageCleanupDecision(
    freeBytes: free,
    cleanupMode: _cleanupMode,
    enteredNow: !wasCleanup && _cleanupMode,
  );
}

enum StorageHeadroomPurpose { download, stream }

/// Extra writable space beyond the downloaded file (cache / TDLib / overhead).
const int kDownloadHeadroomMarginBytes = 50 * 1024 * 1024;

int requiredBytesForPurpose(
  StorageHeadroomPurpose purpose,
  int? catalogFileSizeBytes,
) {
  const mb = 1024 * 1024;
  switch (purpose) {
    case StorageHeadroomPurpose.download:
      final s = catalogFileSizeBytes;
      if (s == null || s <= 0) {
        // No catalog size: do not invent a multi-GB bar; see [ensureStorageHeadroom].
        return 0;
      }
      return s + kDownloadHeadroomMarginBytes;
    case StorageHeadroomPurpose.stream:
      // Range streaming writes a bounded TDLib slice (~150 MiB trim target in
      // telegram_range_playback.dart), not the full file. Do not scale required
      // free space with movie size the way we do for full downloads.
      const base = 280 * mb;
      final s = catalogFileSizeBytes;
      if (s == null || s <= 0) return 320 * mb;
      const prefetchCap = 100 * mb;
      final fivePct = (s * 5) ~/ 100;
      final add = fivePct > prefetchCap ? prefetchCap : fivePct;
      return base + add;
  }
}

String formatStorageHuman(int bytes) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (bytes < 1024) return '$bytes B';
  if (bytes < mb) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(2)} GB';
}

/// True if the action should proceed (enough space, or user chose to continue).
Future<bool> ensureStorageHeadroom({
  required BuildContext context,
  required StorageHeadroomPurpose purpose,
  required int? catalogFileSizeBytes,
}) async {
  final requiredBytes =
      requiredBytesForPurpose(purpose, catalogFileSizeBytes);
  final free = await queryWritableVolumesFreeBytes();
  if (free == null) return true;
  if (purpose == StorageHeadroomPurpose.download && requiredBytes == 0) {
    return true;
  }
  if (free >= requiredBytes) return true;
  if (!context.mounted) return false;

  final verb = purpose == StorageHeadroomPurpose.download
      ? 'download this file'
      : 'stream this video';

  final streamClarifier = purpose == StorageHeadroomPurpose.stream
      ? ' You do not need free space equal to the full video — only a buffer on disk.'
      : '';

  final downloadDetail = purpose == StorageHeadroomPurpose.download
      ? (() {
          final s = catalogFileSizeBytes;
          if (s != null && s > 0) {
            return 'This file is about ${formatStorageHuman(s)} plus about '
                '${formatStorageHuman(kDownloadHeadroomMarginBytes)} for '
                'Telegram cache and overhead '
                '(about ${formatStorageHuman(requiredBytes)} free recommended).';
          }
          return '';
        })()
      : '';

  final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Low storage'),
          content: Text(
            'Free space on storage volumes this app can use is about '
            '${formatStorageHuman(free)}. '
            '${downloadDetail.isNotEmpty ? '$downloadDetail ' : ''}'
            '${downloadDetail.isEmpty ? 'We recommend about ${formatStorageHuman(requiredBytes)} free for $verb (Telegram cache, temp data, and system overhead).' : ''}'
            '$streamClarifier\n\n'
            'You can free space first, or continue anyway — the operation may fail '
            'if the device runs out of space.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Back'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue anyway'),
            ),
          ],
        ),
      ) ??
      false;

  return proceed;
}
