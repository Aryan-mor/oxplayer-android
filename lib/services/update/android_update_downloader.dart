import 'dart:io';

import 'package:dio/dio.dart';

import 'android_update_cache.dart';

class ApkDownloadException implements Exception {
  const ApkDownloadException(this.message);

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
      validateStatus: (status) => status != null && status >= 200 && status < 300,
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
  } on DioException catch (error) {
    if (CancelToken.isCancel(error)) {
      throw const ApkDownloadException('cancelled');
    }
    throw ApkDownloadException(error.message ?? 'Download failed');
  }

  final finished = File(partialPath);
  if (!await finished.exists()) {
    throw const ApkDownloadException('Incomplete download');
  }

  if (await target.exists()) {
    await target.delete();
  }
  await finished.rename(target.path);
}