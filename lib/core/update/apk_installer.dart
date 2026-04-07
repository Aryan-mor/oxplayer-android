import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('oxplayer/apk_install');

/// Opens the system package installer for [absolutePath]. Returns false if nothing handled it.
Future<bool> installDownloadedApk(String absolutePath) async {
  if (!Platform.isAndroid) return false;
  try {
    final ok = await _channel.invokeMethod<bool>('installApk', <String, dynamic>{
      'path': absolutePath,
    });
    return ok ?? false;
  } on PlatformException {
    return false;
  }
}

