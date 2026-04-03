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

/// Version label for prefs: [versionName], or `v{versionCode}` if name is empty.
Future<String?> readAndroidPackageVersionLabel() async {
  try {
    const ch = MethodChannel('telecima/app_info');
    final m = await ch.invokeMethod<Map<dynamic, dynamic>>('getPackageInfo');
    final name = m?['versionName'];
    if (name is String && name.isNotEmpty) return name;
    final code = m?['versionCode'];
    if (code is int) return 'v$code';
    if (code is num) return 'v${code.toInt()}';
  } catch (_) {}
  return null;
}
