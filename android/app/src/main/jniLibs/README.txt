Place prebuilt TDLib JSON client libraries here (required for the `tdlib` Dart package on Android):

  arm64-v8a/libtdjson.so
  armeabi-v7a/libtdjson.so   (required for 32-bit ARM TVs, e.g. many Mi TV builds)
  x86/libtdjson.so          (32-bit emulator / legacy x86 devices)
  x86_64/libtdjson.so       (64-bit emulator)

Build from source: https://github.com/tdlib/td/blob/master/README.md#building
Or use a trusted CI build that matches the TDLib API version bundled with package `tdlib` on pub.dev (see that package’s README).

The app calls DynamicLibrary.open('libtdjson.so'); Android loads native libs from this jniLibs folder into the APK.
