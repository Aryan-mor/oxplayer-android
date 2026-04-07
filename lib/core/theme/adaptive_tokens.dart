import 'package:flutter/material.dart';

import '../device/device_profile.dart';
import 'app_theme.dart';

class AdaptiveTokens {
  const AdaptiveTokens._();

  static EdgeInsetsGeometry controlPadding(DeviceProfile profile) {
    return profile.isTv
        ? const EdgeInsets.symmetric(horizontal: 20, vertical: 14)
        : const EdgeInsets.symmetric(horizontal: 14, vertical: 10);
  }

  static double controlBorderRadius(DeviceProfile profile) {
    return profile.isTv ? 10 : 8;
  }

  static double scaleOnFocus(DeviceProfile profile) {
    return profile.isTv ? 1.05 : 1.02;
  }

  static TextStyle bodyText(BuildContext context, DeviceProfile profile) {
    final base = Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(color: AppColors.onSurfacePrimary);
    return base.copyWith(fontSize: profile.isTv ? 16 : 14);
  }
}
