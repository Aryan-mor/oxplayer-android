import 'package:shared_preferences/shared_preferences.dart';

/// Where video should play: in-app (ExoPlayer) or system/external intent (VLC, etc.).
enum PlaybackSurface { external, internal }

/// Separate remembered defaults for stream vs local file playback.
enum PlaybackSurfaceKind { stream, localFile }

/// Persisted choice when user checks "Remember" on the picker dialog.
/// If unset for that [PlaybackSurfaceKind], the dialog is shown each time.
class PlaybackSurfacePrefs {
  PlaybackSurfacePrefs._();

  static const _keyStream = 'playback_surface_stream';
  static const _keyLocalFile = 'playback_surface_local';

  static String _keyFor(PlaybackSurfaceKind kind) => switch (kind) {
        PlaybackSurfaceKind.stream => _keyStream,
        PlaybackSurfaceKind.localFile => _keyLocalFile,
      };

  static PlaybackSurface? _parse(String? v) {
    if (v == 'internal') return PlaybackSurface.internal;
    if (v == 'external') return PlaybackSurface.external;
    return null;
  }

  static Future<PlaybackSurface?> getSaved(PlaybackSurfaceKind kind) async {
    final p = await SharedPreferences.getInstance();
    return _parse(p.getString(_keyFor(kind)));
  }

  static Future<void> save(
    PlaybackSurfaceKind kind,
    PlaybackSurface surface,
  ) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _keyFor(kind),
      surface == PlaybackSurface.internal ? 'internal' : 'external',
    );
  }

  /// Clears all saved preferences so the picker shows again (e.g. settings).
  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_keyStream);
    await p.remove(_keyLocalFile);
  }
}

