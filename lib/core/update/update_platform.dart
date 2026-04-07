import 'update_platform_stub.dart' if (dart.library.io) 'update_platform_io.dart'
    as plat;

/// True when this build runs on Android (GitHub APK update + ABI selection).
bool get runsAndroidUpdateCheck => plat.runsAndroidUpdateCheck;

