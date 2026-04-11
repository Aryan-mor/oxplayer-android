import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('de.aryanmo.oxplayer/update');

Future<bool> installDownloadedApk(String absolutePath) async {
  if (!Platform.isAndroid) return false;

  try {
    final handled = await _channel.invokeMethod<bool>('installApk', <String, dynamic>{
      'path': absolutePath,
    });
    return handled ?? false;
  } on PlatformException {
    return false;
  }
}