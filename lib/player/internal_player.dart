import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../core/debug/app_debug_log.dart';

/// Full-screen in-app player (Media3 ExoPlayer on Android).
///
/// See [InternalPlayerActivity] in Kotlin.
///
/// [preferredSubtitleLanguage] is passed through from [AuthNotifier] (disk-backed); the player does not request it from the server.
class InternalPlayer {
  InternalPlayer._();

  static const _channel = MethodChannel('oxplayer/internal_player');

  /// Play a URL (e.g. `http://127.0.0.1:port/stream` from [TelegramRangePlayback]).
  static Future<bool> playHttpUrl({
    required String url,
    required String title,
    String? mediaTitle,
    int? releaseYear,
    int? season,
    int? episode,
    bool isSeries = false,
    String? imdbId,
    String? tmdbId,
    String? subdlApiKey,
    String? metadataSubtitle,
    String? preferredSubtitleLanguage,
    String? apiAccessToken,
    String? apiBaseUrl,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final r = await _channel.invokeMethod<bool>('playHttpUrl', {
        'url': url,
        'title': title,
        if (mediaTitle != null) 'mediaTitle': mediaTitle,
        if (releaseYear != null) 'releaseYear': releaseYear,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        'isSeries': isSeries,
        if (imdbId != null && imdbId.isNotEmpty) 'imdbId': imdbId,
        if (tmdbId != null && tmdbId.isNotEmpty) 'tmdbId': tmdbId,
        if (subdlApiKey != null && subdlApiKey.isNotEmpty)
          'subdlApiKey': subdlApiKey,
        if (metadataSubtitle != null && metadataSubtitle.isNotEmpty)
          'metadataSubtitle': metadataSubtitle,
        if (preferredSubtitleLanguage != null &&
            preferredSubtitleLanguage.isNotEmpty)
          'preferredSubtitleLanguage': preferredSubtitleLanguage,
        if (apiAccessToken != null && apiAccessToken.isNotEmpty)
          'apiAccessToken': apiAccessToken,
        if (apiBaseUrl != null && apiBaseUrl.isNotEmpty) 'apiBaseUrl': apiBaseUrl,
      });
      return r ?? false;
    } on PlatformException catch (e) {
      AppDebugLog.instance.log(
        'InternalPlayer: playHttpUrl error: $e',
        category: AppDebugLogCategory.app,
      );
      return false;
    }
  }

  /// Play a completed local file by absolute path.
  static Future<bool> playLocalFile({
    required String path,
    required String title,
    String? mediaTitle,
    int? releaseYear,
    int? season,
    int? episode,
    bool isSeries = false,
    String? imdbId,
    String? tmdbId,
    String? subdlApiKey,
    String? metadataSubtitle,
    String? preferredSubtitleLanguage,
    String? apiAccessToken,
    String? apiBaseUrl,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final r = await _channel.invokeMethod<bool>('playLocalFile', {
        'path': path,
        'title': title,
        if (mediaTitle != null) 'mediaTitle': mediaTitle,
        if (releaseYear != null) 'releaseYear': releaseYear,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
        'isSeries': isSeries,
        if (imdbId != null && imdbId.isNotEmpty) 'imdbId': imdbId,
        if (tmdbId != null && tmdbId.isNotEmpty) 'tmdbId': tmdbId,
        if (subdlApiKey != null && subdlApiKey.isNotEmpty)
          'subdlApiKey': subdlApiKey,
        if (metadataSubtitle != null && metadataSubtitle.isNotEmpty)
          'metadataSubtitle': metadataSubtitle,
        if (preferredSubtitleLanguage != null &&
            preferredSubtitleLanguage.isNotEmpty)
          'preferredSubtitleLanguage': preferredSubtitleLanguage,
        if (apiAccessToken != null && apiAccessToken.isNotEmpty)
          'apiAccessToken': apiAccessToken,
        if (apiBaseUrl != null && apiBaseUrl.isNotEmpty) 'apiBaseUrl': apiBaseUrl,
      });
      return r ?? false;
    } on PlatformException catch (e) {
      AppDebugLog.instance.log(
        'InternalPlayer: playLocalFile error: $e',
        category: AppDebugLogCategory.app,
      );
      return false;
    }
  }
}
