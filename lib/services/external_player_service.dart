import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/external_player_models.dart';
import '../models/plex_metadata.dart';
import '../services/auth_debug_service.dart';
import '../utils/app_logger.dart';
import '../utils/snackbar_helper.dart';
import '../i18n/strings.g.dart';
import 'plex_client.dart';
import 'settings_service.dart';

const _externalPlayerChannel = MethodChannel('com.plezy/external_player');

class ExternalPlayerService {
  /// Force launch using system default external player, ignoring app preference.
  static Future<bool> launchSystemDefault({
    required BuildContext context,
    required String videoUrl,
  }) async {
    try {
      playMediaDebugInfo('Launching system default external player for $videoUrl');
      if (Platform.isAndroid && context.mounted) {
        return _launchAndroidNative(videoUrl, KnownPlayers.systemDefault, context);
      }

      final launched = await KnownPlayers.systemDefault.launch(videoUrl);
      if (!launched && context.mounted) {
        playMediaDebugError('System default external player launch returned false for $videoUrl');
        showErrorSnackBar(context, t.externalPlayer.launchFailed);
      } else if (launched) {
        playMediaDebugSuccess('System default external player launched successfully.');
      }
      return launched;
    } catch (e) {
      appLogger.e('Failed to launch system default player', error: e);
      playMediaDebugError('System default external player launch threw: $e');
      if (context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.launchFailed);
      }
      return false;
    }
  }

  /// Launch an external player with either a pre-resolved [videoUrl] (e.g. local
  /// file path for downloaded content) or by fetching the streaming URL from [client].
  static Future<bool> launch({
    required BuildContext context,
    PlexMetadata? metadata,
    PlexClient? client,
    int mediaIndex = 0,
    String? videoUrl,
  }) async {
    try {
      String resolvedUrl;

      if (videoUrl != null) {
        resolvedUrl = videoUrl;
      } else if (client != null && metadata != null) {
        playMediaDebugInfo(
          'Resolving external playback URL for ${metadata.ratingKey} (mediaIndex=$mediaIndex)',
        );
        final playbackData = await client.getVideoPlaybackData(metadata.ratingKey, mediaIndex: mediaIndex);

        if (!playbackData.hasValidVideoUrl) {
          playMediaDebugError(
            'External playback data did not include a valid video URL for ${metadata.ratingKey}',
          );
          if (context.mounted) {
            showErrorSnackBar(context, t.messages.fileInfoNotAvailable);
          }
          return false;
        }
        resolvedUrl = playbackData.videoUrl!;
      } else {
        appLogger.e('ExternalPlayerService.launch requires either videoUrl or client+metadata');
        return false;
      }

      final settings = await SettingsService.getInstance();
      final player = settings.getSelectedExternalPlayer();
      playMediaDebugInfo('Launching external player ${player.name} (${player.id})');

      // On Android, always use native intent to avoid url_launcher opening in browser
      if (Platform.isAndroid && context.mounted) {
        return _launchAndroidNative(resolvedUrl, player, context);
      }

      final launched = await player.launch(resolvedUrl);
      if (!launched && context.mounted) {
        playMediaDebugError('External player ${player.name} launch returned false for $resolvedUrl');
        showErrorSnackBar(context, t.externalPlayer.appNotInstalled(name: player.name));
      } else if (launched) {
        playMediaDebugSuccess('External player ${player.name} launched successfully.');
      }
      return launched;
    } catch (e) {
      appLogger.e('Failed to launch external player', error: e);
      playMediaDebugError('External player launch threw: $e');
      if (context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.launchFailed);
      }
      return false;
    }
  }

  /// Launch a video on Android using native ACTION_VIEW intent.
  /// Handles local files (file://, content://, absolute paths) and remote URLs.
  static Future<bool> _launchAndroidNative(String url, ExternalPlayer player, BuildContext context) async {
    try {
      playMediaDebugInfo('Launching Android external player ${player.name} (${player.id}) for $url');
      await _externalPlayerChannel.invokeMethod<bool>('openVideo', {
        'filePath': url,
        if (player.id != 'system_default') 'package': _getAndroidPackage(player),
      });
      playMediaDebugSuccess('Android external player ${player.name} intent launched successfully.');
      return true;
    } on PlatformException catch (e) {
      developer.log(
        'Android external player launch failed: code=${e.code}, message=${e.message}, details=${e.details}, player=${player.id}, url=$url',
        name: 'ExternalPlayerService',
        error: e,
      );
      playMediaDebugError(
        'Android external player launch failed: code=${e.code}, message=${e.message}, details=${e.details}, player=${player.id}, url=$url',
      );
      appLogger.e(
        'Android external player launch failed',
        error: {
          'code': e.code,
          'message': e.message,
          'details': e.details,
          'playerId': player.id,
          'playerName': player.name,
          'url': url,
        },
      );
      if (e.code == 'APP_NOT_FOUND' && context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.appNotInstalled(name: player.name));
      } else if (context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.launchFailed);
      }
      return false;
    } catch (e) {
      developer.log(
        'Unexpected Android external player launch failure: $e',
        name: 'ExternalPlayerService',
        error: e,
      );
      playMediaDebugError('Unexpected Android external player launch failure: $e');
      appLogger.e('Unexpected Android external player launch failure', error: e);
      if (context.mounted) {
        showErrorSnackBar(context, t.externalPlayer.launchFailed);
      }
      return false;
    }
  }

  /// Map known player IDs to their Android package names.
  static String? _getAndroidPackage(ExternalPlayer player) {
    const packageMap = {
      'vlc': 'org.videolan.vlc',
      'mpv': 'is.xyz.mpv',
      'mx_player': 'com.mxtech.videoplayer.ad',
      'just_player': 'com.brouken.player',
    };
    // Known players
    if (packageMap.containsKey(player.id)) return packageMap[player.id];
    // Custom command-type players use the value as package name on Android
    if (player.isCustom && player.customType == CustomPlayerType.command) return player.customValue;
    return null;
  }
}
