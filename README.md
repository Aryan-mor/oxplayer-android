# Oxplayer — Flutter (Android TV)

This is the Flutter client for Oxplayer (replacing the legacy React web app). It mirrors the same product shape:

- **Auth gate** (session in `SharedPreferences`, parity with browser `localStorage`)
- **Library + Downloads** tabs, search, poster grid (`cached_network_image`)
- **Isar** metadata (`MediaItem`, `MediaVariant`, `SyncCheckpoint`, `MediaDownload`)
- **Sync parser/engine** (`lib/sync/*`) — GramJS-shaped message maps today; add a TDLib normalizer when wiring TDLib updates
- **Playback bridge** — `TelegramChunkReader` + `TelegramRangePlayback` (loopback HTTP Range → `media_kit` / libmpv), replacing the web Service Worker bridge

## Prerequisites

- Flutter SDK (stable) with the Android toolchain
- NDK + CMake (required by TDLib / `libtdjson` when you integrate it)

## First-time setup

```bash
cd oxplayer-android
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter create . --platforms=android
```

Configure secrets in `assets/env/default.env` (copy from `assets/env/default.example.env` and override locally):

- `TELEGRAM_API_ID` / `TELEGRAM_API_HASH`
- `INDEX_TAG`, `BOT_USERNAME` (same semantics as the Vite app)
- `OXPLAYER_API_BASE_URL`, `OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME` / `OXPLAYER_TELEGRAM_WEBAPP_URL`

**Android TV** is configured in `android/app/src/main/AndroidManifest.xml`:

- `touchscreen` not required, `leanback` required
- `MAIN` + `LEANBACK_LAUNCHER`
- `android:banner="@drawable/oxplayer_banner"` (`android/app/src/main/res/drawable/oxplayer_banner.xml`; replace with a 16:9 asset if you add a custom banner)
- Launcher mipmaps from `assets/AppIcons/android/mipmap-*`

## Libraries (as requested)

| Area | Package |
| --- | --- |
| Telegram core | TDLib via FFI — see [`libtdjson`](https://pub.dev/packages/libtdjson) (implement [`TdlibFacade`](lib/telegram/tdlib_facade.dart)) |
| Player | `media_kit` + `media_kit_video` + `media_kit_libs_android_video` |
| DB | `isar` + `isar_flutter_libs` |
| State / routing | `flutter_riverpod` + `go_router` |
| HTTP / TMDB | `dio` (available for custom calls) + `tmdb_api` |
| Images | `cached_network_image` |
| Paths | `path_provider` |
| Streaming bridge | `shelf` (`import 'package:shelf/shelf_io.dart'` — same package) |

Optional leanback ergonomics: add [`dpad_container`](https://pub.dev/packages/dpad_container) around focusable tiles if you want extra D-pad helpers on top of Flutter’s built-in `Focus` system.

## TDLib streaming (architecture)

1. Implement `TelegramChunkReader` using TDLib file APIs (range reads / streaming).
2. `TelegramRangePlayback.open` exposes `http://127.0.0.1:<port>/stream` with proper `Range`/`206` behaviour.
3. Pass that URI to `media_kit` (`Player.open(Media(uri))`).

This matches the “custom data source” requirement without Service Worker hacks.

## Codegen

Isar models live in `lib/data/local/entities.dart`. After edits, re-run:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## CI / GitHub Actions

Release workflow builds `assets/env/default.env` from repository variables `OXPLAYER_API_BASE_URL`, `OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME`, and `OXPLAYER_TELEGRAM_WEBAPP_URL` (or use the `ENV_FILE_CONTENT` secret for a full file).

## Why `flutter pub outdated` still lists newer packages?

- **`flutter_riverpod` 3.x** — Riverpod 3 pulls `test` constraints that conflict with **`isar_generator`** + **`flutter_test`** from the SDK. Stay on **Riverpod 2.x** until Isar ships a generator compatible with that graph (or you replace Isar).
- **`build_runner` ≥ 2.9** — requires **`package:build` ^4.x**, while **`isar_generator` 3.1.x** requires **`build` ^2.x**. Keep **`build_runner` &lt; 2.9** (see `pubspec.yaml`).
- **Isar queries** — any file that calls `where()` / `filter()` / `findAll()` must `import 'package:isar/isar.dart';` (entity imports alone are not enough for extension methods).

Transitive “discontinued” warnings (`js`, `build_resolvers`, etc.) come from the **build_runner / isar_generator** stack; they are upstream until those tools move
