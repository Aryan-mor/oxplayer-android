import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../router.dart';
import 'external_player.dart';
import 'vlc_install_prompt.dart';

/// Android: [InternalPlayerActivity] queues external playback; [MainActivity]
/// invokes this channel so we reuse the same VLC + launch path as before.
class ExternalPlaybackHandoff {
  ExternalPlaybackHandoff._();

  static const _channel = MethodChannel('oxplayer/playback_handoff');

  static void register() {
    if (kIsWeb || !Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onHandoff') {
        final raw = call.arguments;
        if (raw is! Map) return;
        await _run(Map<String, dynamic>.from(raw));
      }
    });
  }

  static Future<void> _run(Map<String, dynamic> m) async {
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run(m));
      return;
    }

    final kind = m['kind'] as String? ?? 'local';
    final proceed = await ensureVlcOrProceedToExternalPlayer(ctx);
    if (!proceed) return;
    if (!ctx.mounted) return;

    if (kind == 'stream') {
      final url = m['streamUrl'] as String?;
      final title = m['title'] as String? ?? 'Video';
      if (url == null || url.isEmpty) return;
      final mime = (m['mimeType'] as String?)?.trim();
      final launched = await ExternalPlayer.launchStreamUrl(
        url: url,
        title: title,
        mimeType: (mime != null && mime.isNotEmpty) ? mime : 'video/*',
      );
      if (!launched && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('No player found.')),
        );
      }
      return;
    }

    final path = m['localPath'] as String?;
    if (path == null || path.isEmpty) return;

    await ExternalPlayer.injectMetadata(
      path: path,
      title: (m['injectTitle'] as String?) ?? (m['title'] as String?) ?? 'Video',
      year: (m['year'] as String?) ?? '',
      mediaTitle: m['mediaTitle'] as String?,
      displayTitle: m['displayTitle'] as String?,
      subtitle: m['subtitle'] as String?,
      isSeries: m['isSeries'] == true,
    );

    final launched = await ExternalPlayer.launchVideo(
      path: path,
      title: (m['title'] as String?) ?? 'Video',
    );
    if (!launched && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('No player found.')),
      );
    }
  }
}

