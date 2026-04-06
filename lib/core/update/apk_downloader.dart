import 'dart:io';

import 'package:dio/dio.dart';

import 'apk_update_cache.dart';

class ApkDownloadException implements Exception {
  ApkDownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}

Future<void> downloadReleaseApk({
  required String url,
  required CancelToken cancelToken,
  required void Function(int received, int total) onProgress,
}) async {
  final target = await updateApkFile();
  final partialPath = '${target.path}.partial';
  final partial = File(partialPath);
  if (await partial.exists()) {
    await partial.delete();
  }

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 30),
      followRedirects: true,
      validateStatus: (s) => s != null && s >= 200 && s < 300,
      headers: const {'Accept': '*/*'},
    ),
  );

  try {
    await dio.download(
      url,
      partialPath,
      cancelToken: cancelToken,
      deleteOnError: true,
      onReceiveProgress: (received, total) {
        if (total <= 0) {
          onProgress(received, received);
        } else {
          onProgress(received, total);
        }
      },
    );
  } on DioException catch (e) {
    if (CancelToken.isCancel(e)) {
      throw ApkDownloadException('cancelled');
    }
    throw ApkDownloadException(e.message ?? 'Download failed');
  }

  final done = File(partialPath);
  if (!await done.exists()) {
    throw ApkDownloadException('Incomplete download');
  }
  if (await target.exists()) {
    await target.delete();
  }
  await done.rename(target.path);
}
