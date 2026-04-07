import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../focus/input_mode_tracker.dart';

enum DeviceFormFactor { tv, handheld }



class DeviceProfile {
  const DeviceProfile({
    required this.formFactor,
    required this.supportsDynamicOrientation,
  });

  final DeviceFormFactor formFactor;
  final bool supportsDynamicOrientation;

  bool get isTv => formFactor == DeviceFormFactor.tv;
}

class DeviceProfileService {
  DeviceProfileService._();

  static const MethodChannel _channel =
      MethodChannel('de.aryanmo.oxplayer/device_profile');

  static bool? _debugOverrideIsTv;
  static bool? get debugOverrideIsTv => _debugOverrideIsTv;

  /// Global toggle for forcing TV layout rendering and D-pad focus behavior
  /// (even when running on a mobile browser or phone)
  static void toggleDebugTvMode(bool isTv) {
    _debugOverrideIsTv = isTv;
    if (isTv) {
      InputModeTracker.toggleDebugMode(true);
    }
    // Notify flutter engine to rebuild
    WidgetsBinding.instance.reassembleApplication();
  }

  static Future<DeviceProfile> resolve({
    required double logicalWidth,
    required double logicalHeight,
  }) async {
    final isTv = _debugOverrideIsTv ?? (await _detectAndroidTvFeature() || _detectByScreenHeuristics(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
    ));

    return DeviceProfile(
      formFactor: isTv ? DeviceFormFactor.tv : DeviceFormFactor.handheld,
      supportsDynamicOrientation: !isTv,
    );
  }

  static Future<bool> _detectAndroidTvFeature() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isAndroidTv');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static bool _detectByScreenHeuristics({
    required double logicalWidth,
    required double logicalHeight,
  }) {
    final shortest = logicalWidth < logicalHeight ? logicalWidth : logicalHeight;
    final longest = logicalWidth > logicalHeight ? logicalWidth : logicalHeight;
    return shortest >= 600 && longest >= 960;
  }
}
