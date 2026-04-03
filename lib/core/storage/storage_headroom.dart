import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _kChannel = MethodChannel('telecima/storage_space');

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

enum StorageHeadroomPurpose { download, stream }

int requiredBytesForPurpose(
  StorageHeadroomPurpose purpose,
  int? catalogFileSizeBytes,
) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  switch (purpose) {
    case StorageHeadroomPurpose.download:
      const margin = 200 * mb;
      final s = catalogFileSizeBytes;
      if (s == null || s <= 0) return 4 * gb;
      return s + margin;
    case StorageHeadroomPurpose.stream:
      const base = 400 * mb;
      final s = catalogFileSizeBytes;
      if (s == null || s <= 0) return base;
      final sixPct = (s * 6) ~/ 100;
      const cap = 900 * mb;
      final add = sixPct > cap ? cap : sixPct;
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
  if (free >= requiredBytes) return true;
  if (!context.mounted) return false;

  final verb = purpose == StorageHeadroomPurpose.download
      ? 'download this file'
      : 'stream this video';

  final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Low storage'),
          content: Text(
            'Free space on storage volumes this app can use is about '
            '${formatStorageHuman(free)}. We recommend about '
            '${formatStorageHuman(requiredBytes)} free for $verb '
            '(Telegram cache, temp data, and system overhead).\n\n'
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
