import 'package:flutter/services.dart';

/// [PackageInfo.version]-style string from the Android host (no `package_info_plus` Gradle plugin).
Future<String?> readAndroidPackageVersionName() async {
  try {
    const ch = MethodChannel('telecima/app_info');
    final m = await ch.invokeMethod<Map<dynamic, dynamic>>('getPackageInfo');
    final name = m?['versionName'];
    if (name is String && name.isNotEmpty) return name;
  } catch (_) {}
  return null;
}
